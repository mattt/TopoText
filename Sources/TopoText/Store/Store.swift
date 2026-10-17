import Foundation

/// Read-only access to the database of the Notes app.
///
/// A store reads the `NoteStore.sqlite` database in the Notes folder,
/// `~/Library/Group Containers/group.com.apple.notes`.
/// It never writes to the database, copies it, or changes its journal mode.
///
/// A store runs one operation at a time on a private dispatch queue,
/// outside Swift's cooperative thread pool.
/// Each operation opens its own read-only connection and closes it before it returns,
/// so a store holds no connection between operations.
/// Operations run as part of the calling task:
/// canceling the task stops SQL statements and the decoding of a search.
///
/// The caller must have access to the Notes folder, for example through Full Disk Access
/// or a security-scoped bookmark of the folder; TopoText does not request permissions.
/// The access must cover the folder and not only the database file,
/// because SQLite also reads the `-wal` and `-shm` files next to it.
/// Keep any security scope active until each call returns or throws;
/// by then, the store has finished all database and file work for that call.
public actor Store {
    /// Limits on the work that a store does in the database.
    public struct Configuration: Sendable, Hashable {
        /// The time limit for each operation, including every statement of a snapshot.
        ///
        /// An operation holds a read transaction, which can delay the WAL checkpoints of Notes.
        /// When the limit passes, the operation throws ``NotesError/timedOut``.
        /// The limit is cooperative: SQLite checks it between steps,
        /// so it can't stop a statement that is blocked in file I/O.
        public let timeLimit: Duration

        /// The default limit: 10 seconds for each operation.
        public static let `default` = Configuration(validTimeLimit: .seconds(10))

        /// Creates limits for a store.
        /// - Parameter timeLimit: The time limit for each operation. The value must be positive.
        /// - Throws: ``ValidationError/invalidTimeLimit`` if the time limit is not positive.
        public init(timeLimit: Duration = Configuration.default.timeLimit) throws {
            guard timeLimit > .zero else {
                throw ValidationError.invalidTimeLimit
            }
            self.init(validTimeLimit: timeLimit)
        }

        private init(validTimeLimit: Duration) {
            timeLimit = validTimeLimit
        }
    }

    /// The notes that match a search.
    public struct SearchResult: Sendable, Hashable {
        /// The matching notes, newest first.
        public let notes: [Note]
        /// The position after which the next page starts, or `nil` if no more notes can match.
        ///
        /// For a search with a query, the cursor follows the last note that the search examined,
        /// which can come after the last match.
        /// Set ``Note/FetchRequest/cursor`` to this value to continue the search.
        public let nextCursor: Note.FetchRequest.Cursor?
        /// The number of notes that the search examined.
        public let scannedNoteCount: Int
        /// The notes whose contents could not be decoded, so that the search matched them by title and preview alone.
        public let unreadableNoteIDs: [Note.ID]
        /// The request that selected the notes.
        public let request: Note.FetchRequest
    }

    /// A read-only view of the database in which every query reads the same snapshot.
    ///
    /// A snapshot is valid only inside the closure that receives it.
    /// After the closure returns, its queries throw ``NotesError/connectionClosed``.
    public struct Snapshot {
        let database: Database

        /// Returns the accounts in the database.
        /// - Returns: The accounts, ordered by name.
        /// - Throws: A ``NotesError`` if the database can't be read, or `CancellationError`.
        public func accounts() throws -> [Account] {
            try database.accounts()
        }

        /// Returns the folders in the database, except smart folders.
        /// - Returns: The folders, ordered by account name, with Recently Deleted last in each account,
        ///   and then by name.
        /// - Throws: A ``NotesError`` if the database can't be read, or `CancellationError`.
        public func folders() throws -> [Folder] {
            try database.folders()
        }

        /// Returns the notes that match a request.
        /// - Parameter request: The filters and pagination.
        /// - Returns: The matching notes, the cursor of the next page, and the request.
        /// - Throws: A ``Note/FetchRequest/ValidationError`` if the request is invalid,
        ///   ``NotesError/storeChanged`` if the cursor is from another database,
        ///   ``NotesError/folderNotFound(_:)`` if a folder is not in the database,
        ///   another ``NotesError`` if the database can't be read, or `CancellationError`.
        public func search(_ request: Note.FetchRequest) throws -> SearchResult {
            try database.search(request)
        }

        /// Returns the current values of a note.
        ///
        /// The note can be in Recently Deleted.
        /// - Parameter identifier: The identifier of the note.
        /// - Returns: The note.
        /// - Throws: ``NotesError/noteNotFound(_:)`` if Notes doesn't list a note with the identifier,
        ///   another ``NotesError`` if the database can't be read, or `CancellationError`.
        public func note(for identifier: Note.ID) throws -> Note {
            try database.note(for: identifier)
        }

        /// Returns the contents of a note, with its attachments and tables resolved.
        /// - Parameter identifier: The identifier of the note.
        /// - Returns: The paragraphs of the note.
        /// - Throws: ``NotesError/noteNotFound(_:)`` if Notes doesn't list a note with the identifier,
        ///   ``NotesError/noteLocked(_:)`` if the note is locked,
        ///   ``NotesError/contentNotFound(_:)`` if the database has no contents for the note,
        ///   ``NotesError/unsupportedContent(_:)`` or ``NotesError/malformedContent(_:)``
        ///   if the contents can't be decoded,
        ///   another ``NotesError`` if the database can't be read, or `CancellationError`.
        public func content(for identifier: Note.ID) throws -> Note.Content {
            try database.content(for: identifier)
        }

        /// Returns the location of the file that holds an attachment, if the folder has one.
        /// - Parameter identifier: The identifier of the attachment.
        /// - Returns: The file, with symbolic links resolved, or `nil` if no file is found.
        /// - Throws: ``NotesError/attachmentNotFound(_:)`` if the database has no such attachment,
        ///   ``NotesError/noteLocked(_:)`` if the attachment's note is locked,
        ///   another ``NotesError`` if the database can't be read, or `CancellationError`.
        public func fileURL(for identifier: Note.Attachment.ID) throws -> URL? {
            Database.firstFile(in: try database.fileCandidates(for: identifier), root: database.root)
        }
    }

    /// The Notes folder for the user who runs the process,
    /// `~/Library/Group Containers/group.com.apple.notes`.
    ///
    /// The location is in the user's home folder, also in a sandboxed app.
    public static var defaultRoot: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes", isDirectory: true)
    }

    /// The Notes folder, which contains `NoteStore.sqlite`.
    public nonisolated let root: URL
    /// The limits that apply to each operation.
    public nonisolated let configuration: Configuration

    private nonisolated let queue = DispatchSerialQueue(label: "me.mattt.TopoText.store")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Creates a store for a Notes folder, without reading it.
    ///
    /// Call ``checkAccess()`` to check that the folder can be read.
    /// - Parameters:
    ///   - root: The Notes folder, `group.com.apple.notes`.
    ///   - configuration: The limits that apply to each operation.
    public init(root: URL = Store.defaultRoot, configuration: Configuration = .default) {
        self.root = root
        self.configuration = configuration
    }

    /// Checks that the store can open the database and read its schema.
    ///
    /// The check opens a connection, checks the tables and entities that TopoText reads,
    /// and closes the connection without reading any notes.
    /// Call it after the caller gets access to the Notes folder, such as after the user grants it.
    /// - Throws: A ``NotesError`` if the folder or the database can't be read,
    ///   or if the database has an unsupported schema; or `CancellationError`.
    public func checkAccess() throws {
        try withDatabase { _ in }
    }

    /// Returns the accounts in the database.
    /// - Returns: The accounts, ordered by name.
    /// - Throws: A ``NotesError`` if the database can't be read, or `CancellationError`.
    public func accounts() throws -> [Account] {
        try withSnapshot { try $0.accounts() }
    }

    /// Returns the folders in the database, except smart folders.
    /// - Returns: The folders, ordered by account name, with Recently Deleted last in each account,
    ///   and then by name.
    /// - Throws: A ``NotesError`` if the database can't be read, or `CancellationError`.
    public func folders() throws -> [Folder] {
        try withSnapshot { try $0.folders() }
    }

    /// Returns the notes that match a request, from one snapshot.
    /// - Parameter request: The filters and pagination.
    /// - Returns: The matching notes, the cursor of the next page, and the request.
    /// - Throws: A ``Note/FetchRequest/ValidationError`` if the request is invalid,
    ///   ``NotesError/storeChanged`` if the cursor is from another database,
    ///   ``NotesError/folderNotFound(_:)`` if a folder is not in the database,
    ///   another ``NotesError`` if the database can't be read, or `CancellationError`.
    public func search(_ request: Note.FetchRequest) throws -> SearchResult {
        try withSnapshot { try $0.search(request) }
    }

    /// Returns the current values of a note.
    ///
    /// The note can be in Recently Deleted.
    /// - Parameter identifier: The identifier of the note.
    /// - Returns: The note.
    /// - Throws: ``NotesError/noteNotFound(_:)`` if Notes doesn't list a note with the identifier,
    ///   another ``NotesError`` if the database can't be read, or `CancellationError`.
    public func note(for identifier: Note.ID) throws -> Note {
        try withSnapshot { try $0.note(for: identifier) }
    }

    /// Returns the contents of a note, with its attachments and tables resolved.
    /// - Parameter identifier: The identifier of the note.
    /// - Returns: The paragraphs of the note.
    /// - Throws: ``NotesError/noteNotFound(_:)`` if Notes doesn't list a note with the identifier,
    ///   ``NotesError/noteLocked(_:)`` if the note is locked,
    ///   ``NotesError/contentNotFound(_:)`` if the database has no contents for the note,
    ///   ``NotesError/unsupportedContent(_:)`` or ``NotesError/malformedContent(_:)``
    ///   if the contents can't be decoded,
    ///   another ``NotesError`` if the database can't be read, or `CancellationError`.
    public func content(for identifier: Note.ID) throws -> Note.Content {
        try withSnapshot { try $0.content(for: identifier) }
    }

    /// Returns the location of the file that holds an attachment, if the folder has one.
    ///
    /// The store reads the attachment's row, closes its connection,
    /// and then looks for the file.
    /// The store looks in the places that <doc:NoteStore> lists;
    /// it doesn't find a file that Notes keeps elsewhere.
    /// - Parameter identifier: The identifier of the attachment.
    /// - Returns: The file, with symbolic links resolved, or `nil` if no file is found.
    /// - Throws: ``NotesError/attachmentNotFound(_:)`` if the database has no such attachment,
    ///   ``NotesError/noteLocked(_:)`` if the attachment's note is locked,
    ///   another ``NotesError`` if the database can't be read, or `CancellationError`.
    public func fileURL(for identifier: Note.Attachment.ID) throws -> URL? {
        let candidates = try withDatabase { try $0.fileCandidates(for: identifier) }
        // The connection is closed here, before file I/O.
        try Task.checkCancellation()
        return Database.firstFile(in: candidates, root: root)
    }

    /// Runs several queries in one snapshot of the database.
    ///
    /// The snapshot holds a read transaction until the closure returns,
    /// which can delay the WAL checkpoints of Notes.
    /// Its statements stop at ``Configuration/timeLimit``.
    /// - Parameter body: A closure that queries the snapshot.
    ///   The snapshot is not valid after the closure returns.
    /// - Returns: The value that `body` returns.
    /// - Throws: A ``NotesError``, the error that `body` throws, or `CancellationError`.
    public func withSnapshot<T: Sendable>(_ body: @Sendable (Snapshot) throws -> T) throws -> T {
        try withDatabase { database in
            try database.readTransaction {
                try body(Snapshot(database: database))
            }
        }
    }

    /// Opens a connection for one operation and closes it before returning.
    func withDatabase<T>(_ body: (Database) throws -> T) throws -> T {
        let database = try Database(root: root, timeLimit: configuration.timeLimit)
        defer { database.close() }
        return try body(database)
    }
}

@available(*, unavailable)
extension Store.Snapshot: Sendable {}
