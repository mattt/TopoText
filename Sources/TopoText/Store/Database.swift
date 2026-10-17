import Foundation
import SQLite3

/// A read-only connection to the database that the Notes app keeps
/// in `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`.
///
/// Notes stores accounts, folders, notes, and attachments as rows of one Core Data table,
/// `ZICCLOUDSYNCINGOBJECT`, told apart by entity (`Z_ENT`, named in `Z_PRIMARYKEY`).
/// Columns that several entities define get numbered suffixes, such as `ZTITLE1` for note
/// titles and `ZTITLE2` for folder names, and some move between releases, so queries
/// read the columns that the table has and NULL in place of any it lacks.
/// Note contents are gzip-compressed protocol buffers in `ZICNOTEDATA`.
///
/// The connection reads the live database and its write-ahead log, without a copy.
/// Use a connection from one thread at a time, and close it when you finish.
final class Database {
    /// The name of the database file in the Notes folder.
    static let fileName = "NoteStore.sqlite"

    /// The Notes folder.
    let root: URL
    /// The database file.
    let databaseURL: URL
    /// The names of the columns of `ZICCLOUDSYNCINGOBJECT`.
    private(set) var columns: Set<String> = []
    /// The names of the columns of `ZICNOTEDATA`.
    private(set) var noteDataColumns: Set<String> = []
    /// Core Data entity numbers, keyed by entity name.
    /// The numbers differ between databases, so they are looked up rather than assumed.
    private(set) var entities: [String: Int64] = [:]
    /// The UUID of the database in `Z_METADATA`, or an empty string if it has none.
    private(set) var storeUUID = ""

    private var connection: OpaquePointer?
    /// The time at which statements stop.
    private let deadline: ContinuousClock.Instant

    /// Opens a read-only connection to the database in a Notes folder and reads its schema.
    ///
    /// The caller must have access to the folder.
    /// Keep any security scope active until ``close()`` returns.
    /// - Parameters:
    ///   - root: The Notes folder, `group.com.apple.notes`.
    ///   - timeLimit: The time limit for all the statements of the connection.
    /// - Throws: A ``NotesError`` if the database can't be found or read,
    ///   or has an unsupported schema; or `CancellationError`.
    init(root: URL, timeLimit: Duration) throws {
        try Task.checkCancellation()
        self.root = root
        databaseURL = root.appendingPathComponent(Self.fileName)
        deadline = ContinuousClock.now.advanced(by: timeLimit)

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            let canList = (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil
            throw canList ? NotesError.storeNotFound : NotesError.storeNotReadable
        }
        do {
            try open(immutable: false)
        } catch NotesError.storeNotReadable where !fileManager.fileExists(atPath: databaseURL.path + "-wal") {
            // A reader of a WAL-mode database needs the `-shm` file, and SQLite can't create it
            // in a folder that is read-only. Without a log, every record is in the main file,
            // so reading the main file alone loses nothing.
            try open(immutable: true)
        }
    }

    deinit {
        close()
    }

    /// Closes the connection.
    ///
    /// Call this method before the security scope of the Notes folder ends.
    /// Later calls do nothing.
    func close() {
        sqlite3_close(connection)
        connection = nil
    }

    /// Opens the database and reads its schema.
    ///
    /// With `immutable`, SQLite ignores the write-ahead log and never touches the `-wal`
    /// and `-shm` files, so it sees only the records in the main file.
    private func open(immutable: Bool) throws {
        var filename = databaseURL.path
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE
        if immutable {
            var components = URLComponents()
            components.scheme = "file"
            components.path = databaseURL.path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = components.string else {
                throw NotesError.storeNotReadable
            }
            filename = uri
            flags |= SQLITE_OPEN_URI
        }

        guard sqlite3_open_v2(filename, &connection, flags, nil) == SQLITE_OK else {
            close()
            throw NotesError.storeNotReadable
        }
        sqlite3_busy_timeout(connection, 1000)
        sqlite3_progress_handler(
            connection,
            1000,
            { context in
                guard let context else { return 1 }
                return Unmanaged<Database>.fromOpaque(context).takeUnretainedValue().shouldStop ? 1 : 0
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        do {
            // The first statement reads the file, so its failure means the database is not readable.
            let tables: Set<String>
            do {
                tables = Set(try query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) }.compactMap { $0 })
            } catch NotesError.queryFailed {
                throw NotesError.storeNotReadable
            }
            guard tables.isSuperset(of: ["ZICCLOUDSYNCINGOBJECT", "ZICNOTEDATA", "Z_PRIMARYKEY"]) else {
                throw NotesError.unsupportedSchema
            }

            columns = Set(try query("SELECT name FROM pragma_table_info('ZICCLOUDSYNCINGOBJECT')") { $0.text(0) }.compactMap { $0 })
            noteDataColumns = Set(try query("SELECT name FROM pragma_table_info('ZICNOTEDATA')") { $0.text(0) }.compactMap { $0 })
            for (name, number) in try query("SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY", transform: { ($0.text(0), $0.integer(1)) }) {
                if let name, let number {
                    entities[name] = number
                }
            }
            guard entities["ICNote"] != nil, entities["ICFolder"] != nil,
                columns.isSuperset(of: ["Z_PK", "Z_ENT", "ZIDENTIFIER"]),
                noteDataColumns.isSuperset(of: ["Z_PK", "ZDATA"])
            else {
                throw NotesError.unsupportedSchema
            }
            if tables.contains("Z_METADATA") {
                storeUUID = try query("SELECT Z_UUID FROM Z_METADATA LIMIT 1") { $0.text(0) }.first.flatMap { $0 } ?? ""
            }
        } catch {
            close()
            throw error
        }
    }

    // MARK: Statements

    /// Runs statements in one read transaction, so that they read the same snapshot.
    ///
    /// The transaction ends even if the time limit has passed or the work is canceled,
    /// because an open read transaction delays WAL checkpoints.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        // A snapshot already holds a transaction; its statements share it.
        if let connection, sqlite3_get_autocommit(connection) == 0 {
            return try body()
        }
        try query("BEGIN") { _ in }
        defer {
            if let connection, sqlite3_get_autocommit(connection) == 0 {
                sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
            }
        }
        return try body()
    }

    /// Runs a statement and transforms each row of its result.
    @discardableResult
    func query<T>(
        _ sql: String,
        _ bindings: [Binding] = [],
        transform: (Row) throws -> T
    ) throws -> [T] {
        guard let connection else { throw NotesError.connectionClosed }
        try checkBudget()

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try checkResult(sqlite3_prepare_v2(connection, sql, -1, &statement, nil))

        for (offset, binding) in bindings.enumerated() {
            try checkResult(binding.bind(to: statement, at: Int32(offset + 1)))
        }

        var results: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            results.append(try transform(Row(statement: statement)))
            try checkBudget()
            result = sqlite3_step(statement)
        }
        try checkResult(result)
        return results
    }

    /// Throws if the task is canceled or the time limit has passed.
    ///
    /// Statements check this themselves; call it between steps of work outside SQLite,
    /// such as decoding notes.
    /// - Throws: `CancellationError` or ``NotesError/timedOut``.
    func checkBudget() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw NotesError.timedOut }
    }

    /// Whether the progress handler should interrupt the running statement.
    private var shouldStop: Bool {
        Task.isCancelled || ContinuousClock.now >= deadline
    }

    /// Converts a SQLite result code to an error.
    private func checkResult(_ result: Int32) throws {
        switch result & 0xff {
        case SQLITE_OK, SQLITE_DONE:
            return
        case SQLITE_INTERRUPT:
            try checkBudget()
            throw NotesError.queryFailed(String(cString: sqlite3_errmsg(connection)))
        case SQLITE_BUSY, SQLITE_LOCKED:
            throw NotesError.databaseBusy
        default:
            throw NotesError.queryFailed(String(cString: sqlite3_errmsg(connection)))
        }
    }

    // MARK: Schema

    /// Returns the entity number of an entity.
    /// - Throws: ``NotesError/unsupportedSchema`` if the database has no such entity.
    func entity(_ name: String) throws -> Int64 {
        guard let number = entities[name] else {
            throw NotesError.unsupportedSchema
        }
        return number
    }

    /// The first of the candidate columns that `ZICCLOUDSYNCINGOBJECT` has, qualified by the alias,
    /// or NULL when it has none of them.
    func column(_ alias: String, _ candidates: String...) -> String {
        guard let name = candidates.first(where: columns.contains) else { return "NULL" }
        return "\(alias).\(name)"
    }

    /// The first non-NULL value among the candidate columns that `ZICCLOUDSYNCINGOBJECT` has.
    func coalesce(_ alias: String, _ candidates: String...) -> String {
        let names = candidates.filter(columns.contains).map { "\(alias).\($0)" }
        switch names.count {
        case 0: return "NULL"
        case 1: return names[0]
        default: return "COALESCE(\(names.joined(separator: ", ")))"
        }
    }
}

extension Database {
    /// A value bound to a `?` placeholder in a prepared statement.
    enum Binding {
        case text(String)
        case double(Double)
        case integer(Int64)

        func bind(to statement: OpaquePointer?, at index: Int32) -> Int32 {
            switch self {
            case .text(let string):
                return sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case .double(let double):
                return sqlite3_bind_double(statement, index, double)
            case .integer(let integer):
                return sqlite3_bind_int64(statement, index, integer)
            }
        }
    }

    /// The current row of a prepared statement.
    ///
    /// The accessors return `nil` for `NULL` values, and ``text(_:)`` also for empty strings.
    struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            guard !isNull(column), let cString = sqlite3_column_text(statement, column) else { return nil }
            let string = String(cString: cString)
            return string.isEmpty ? nil : string
        }

        func integer(_ column: Int32) -> Int64? {
            isNull(column) ? nil : sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double? {
            isNull(column) ? nil : sqlite3_column_double(statement, column)
        }

        func blob(_ column: Int32) -> Data? {
            guard !isNull(column), let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }

        private func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Returns a list of `count` placeholders for an `IN` clause.
func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
