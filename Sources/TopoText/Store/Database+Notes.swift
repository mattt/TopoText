import Foundation

extension Database {
    // MARK: Conditions

    /// A condition that leaves out rows marked for deletion.
    ///
    /// Rows marked for deletion are already deleted and wait for the deletion to sync.
    /// Notes in Recently Deleted are not marked; they are in that folder.
    func notMarkedForDeletion(_ alias: String) -> String {
        "COALESCE(\(column(alias, "ZMARKEDFORDELETION")), 0) = 0"
    }

    /// A condition that matches the notes that the Notes app lists.
    ///
    /// Other note rows, such as drafts of Quick Notes, have no title or no folder.
    func isListedNote(_ alias: String) throws -> String {
        [
            "\(alias).Z_ENT = \(try entity("ICNote"))",
            "\(alias).ZIDENTIFIER IS NOT NULL",
            notMarkedForDeletion(alias),
            "\(column(alias, "ZTITLE1")) IS NOT NULL",
            "\(column(alias, "ZFOLDER")) IS NOT NULL",
        ].joined(separator: " AND ")
    }

    /// A condition that matches the folders that the Notes app lists, except smart folders.
    ///
    /// Smart folders collect notes by a query and hold none of their own.
    /// The sources disagree on the `ZFOLDERTYPE` of a smart folder,
    /// so a folder counts as smart when it has a query.
    /// Folders that Notes has not fetched from iCloud yet are left out too.
    func isListedFolder(_ alias: String) throws -> String {
        [
            "\(alias).Z_ENT = \(try entity("ICFolder"))",
            "\(alias).ZIDENTIFIER IS NOT NULL",
            notMarkedForDeletion(alias),
            "COALESCE(LENGTH(\(column(alias, "ZSMARTFOLDERQUERYJSON"))), 0) = 0",
            "COALESCE(\(column(alias, "ZNEEDSINITIALFETCHFROMCLOUD")), 0) = 0",
        ].joined(separator: " AND ")
    }

    /// An expression that is 1 for an account's Recently Deleted folder and 0 otherwise.
    ///
    /// Recently Deleted has the `ZFOLDERTYPE` 1, or an identifier that starts with `TrashFolder`.
    func isRecentlyDeleted(_ alias: String) -> String {
        """
        (COALESCE(\(column(alias, "ZFOLDERTYPE")), 0) = 1 \
        OR COALESCE(\(alias).ZIDENTIFIER, '') LIKE 'TrashFolder%')
        """
    }

    // MARK: Accounts and folders

    /// Returns the accounts, ordered by name.
    func accounts() throws -> [Account] {
        guard let entity = entities["ICAccount"] else { return [] }
        let sql = """
            SELECT a.ZIDENTIFIER, \(column("a", "ZNAME"))
            FROM ZICCLOUDSYNCINGOBJECT a
            WHERE a.Z_ENT = ? AND a.ZIDENTIFIER IS NOT NULL AND \(notMarkedForDeletion("a"))
            """
        let accounts = try query(sql, [.integer(entity)]) { row in
            row.text(0).flatMap(Account.ID.init(_:)).map { Account(id: $0, name: row.text(1)) }
        }
        return accounts.compactMap { $0 }.sorted {
            ($0.name?.lowercased() ?? "", $0.id.description) < ($1.name?.lowercased() ?? "", $1.id.description)
        }
    }

    /// Returns the folders, except smart folders,
    /// ordered by account name, with Recently Deleted last in each account, then by name.
    func folders() throws -> [Folder] {
        let sql = """
            SELECT f.ZIDENTIFIER, \(column("f", "ZTITLE2")), p.ZIDENTIFIER, a.ZIDENTIFIER, \(column("a", "ZNAME")),
                \(isRecentlyDeleted("f")),
                (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                    WHERE \(try isListedNote("n")) AND \(column("n", "ZFOLDER")) = f.Z_PK)
            FROM ZICCLOUDSYNCINGOBJECT f
            LEFT JOIN ZICCLOUDSYNCINGOBJECT p ON p.Z_PK = \(column("f", "ZPARENT"))
            LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = \(column("f", "ZOWNER"))
            WHERE \(try isListedFolder("f"))
            """
        let folders = try query(sql) { row -> Folder? in
            guard let id = row.text(0).flatMap(Folder.ID.init(_:)) else { return nil }
            let isRecentlyDeleted = row.integer(5) == 1
            return Folder(
                id: id,
                name: row.text(1) ?? (isRecentlyDeleted ? "Recently Deleted" : "Notes"),
                parentID: row.text(2).flatMap(Folder.ID.init(_:)),
                account: row.text(3).flatMap(Account.ID.init(_:)).map { Account(id: $0, name: row.text(4)) },
                isRecentlyDeleted: isRecentlyDeleted,
                noteCount: Int(row.integer(6) ?? 0)
            )
        }
        return folders.compactMap { $0 }.sorted {
            ($0.account?.name ?? "", $0.isRecentlyDeleted ? 1 : 0, $0.name.lowercased(), $0.id.description)
                < ($1.account?.name ?? "", $1.isRecentlyDeleted ? 1 : 0, $1.name.lowercased(), $1.id.description)
        }
    }

    /// Returns the rows of listed folders.
    /// - Throws: ``NotesError/folderNotFound(_:)`` for the first identifier with no listed folder.
    private func folderRows(_ identifiers: Set<Folder.ID>) throws -> [Int64] {
        guard !identifiers.isEmpty else { return [] }
        let sql = """
            SELECT f.Z_PK, f.ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT f
            WHERE \(try isListedFolder("f")) AND f.ZIDENTIFIER IN (\(placeholders(identifiers.count)))
            """
        let rows = try query(sql, identifiers.map { .text($0.description) }) { row in
            (row.integer(0), row.text(1).flatMap(Folder.ID.init(_:)))
        }
        let found = Set(rows.compactMap(\.1))
        if let missing = identifiers.subtracting(found).min(by: { $0.description < $1.description }) {
            throw NotesError.folderNotFound(missing)
        }
        return rows.compactMap(\.0)
    }

    // MARK: Notes

    /// The sort key of a note: its modification date, or a value below every date.
    private var sortKey: String {
        "COALESCE(\(column("n", "ZMODIFICATIONDATE1")), \(Note.missingDateKey))"
    }

    /// The select list that ``note(_:)`` reads, from a note `n` and its folder `f`.
    private var noteColumns: String {
        [
            "n.Z_PK",
            "n.ZIDENTIFIER",
            column("n", "ZTITLE1"),
            "NULLIF(\(coalesce("n", "ZSNIPPET", "ZWIDGETSNIPPET")), '')",
            "f.ZIDENTIFIER",
            // Notes moved the creation date between columns across releases.
            coalesce("n", "ZCREATIONDATE3", "ZCREATIONDATE2", "ZCREATIONDATE1"),
            column("n", "ZMODIFICATIONDATE1"),
            column("n", "ZISPINNED"),
            column("n", "ZISPASSWORDPROTECTED"),
            isRecentlyDeleted("f"),
            sortKey,
        ].joined(separator: ", ")
    }

    /// The tables that ``noteColumns`` reads from.
    private var noteTables: String {
        "ZICCLOUDSYNCINGOBJECT n LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = \(column("n", "ZFOLDER"))"
    }

    /// Reads the current row of a statement that selects ``noteColumns``.
    private func note(_ row: Row) throws -> Note {
        guard let rowID = row.integer(0), let id = row.text(1).flatMap(Note.ID.init(_:)), let sortKey = row.double(10) else {
            throw NotesError.unsupportedSchema
        }
        let isLocked = row.integer(8) == 1
        return Note(
            id: id,
            title: row.text(2) ?? "",
            // A locked note's stored preview can still hold text from before it was locked.
            snippet: isLocked ? nil : row.text(3),
            folderID: row.text(4).flatMap(Folder.ID.init(_:)),
            isRecentlyDeleted: row.integer(9) == 1,
            creationDate: row.double(5).map(Date.init(timeIntervalSinceReferenceDate:)),
            modificationDate: row.double(6).map(Date.init(timeIntervalSinceReferenceDate:)),
            isPinned: row.integer(7) == 1,
            isLocked: isLocked,
            rowID: rowID,
            sortKey: sortKey,
            store: storeUUID
        )
    }

    /// Returns a note that Notes lists, including notes in Recently Deleted.
    /// - Throws: ``NotesError/noteNotFound(_:)`` if there is none with the identifier.
    func note(for identifier: Note.ID) throws -> Note {
        let sql = """
            SELECT \(noteColumns) FROM \(noteTables)
            WHERE \(try isListedNote("n")) AND n.ZIDENTIFIER = ?
            LIMIT 1
            """
        guard let note = try query(sql, [.text(identifier.description)], transform: note).first else {
            throw NotesError.noteNotFound(identifier)
        }
        return note
    }

    /// Returns the notes that match a request, newest first.
    ///
    /// All the statements read one snapshot.
    func search(_ request: Note.FetchRequest) throws -> Store.SearchResult {
        try request.validate()
        // A row number names a different note in another database.
        if let cursor = request.cursor, cursor.store != storeUUID {
            throw NotesError.storeChanged
        }

        return try readTransaction {
            var conditions = [try isListedNote("n")]
            var bindings: [Binding] = []

            if let folderIDs = request.folderIDs {
                let rows = try folderRows(folderIDs)
                conditions.append("\(column("n", "ZFOLDER")) IN (\(placeholders(rows.count)))")
                bindings += rows.map { .integer($0) }
            } else if !request.includesRecentlyDeleted {
                conditions.append("NOT \(isRecentlyDeleted("f"))")
            }
            let modified = column("n", "ZMODIFICATIONDATE1")
            if let startDate = request.startDate {
                conditions.append("\(modified) >= ?")
                bindings.append(.double(startDate.timeIntervalSinceReferenceDate))
            }
            if let endDate = request.endDate {
                conditions.append("\(modified) < ?")
                bindings.append(.double(endDate.timeIntervalSinceReferenceDate))
            }
            if let cursor = request.cursor {
                // Results are newest first, so the next page starts below the cursor.
                conditions.append("(\(sortKey) < ? OR (\(sortKey) = ? AND n.Z_PK < ?))")
                bindings += [.double(cursor.sortKey), .double(cursor.sortKey), .integer(cursor.rowID)]
            }

            // A query can match contents that only decoding reveals, so a search reads
            // up to the scan limit of candidates and filters them here.
            // One extra row shows whether more candidates follow.
            let query = request.trimmedQuery
            bindings.append(.integer(Int64(query == nil ? request.limit : request.scanLimit) + 1))
            let sql = """
                SELECT \(noteColumns) FROM \(noteTables)
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY \(sortKey) DESC, n.Z_PK DESC
                LIMIT ?
                """
            let candidates = try self.query(sql, bindings, transform: note)

            guard let query else {
                let notes = Array(candidates.prefix(request.limit))
                return Store.SearchResult(
                    notes: notes,
                    nextCursor: candidates.count > request.limit ? notes.last.map(Note.FetchRequest.Cursor.init(after:)) : nil,
                    scannedNoteCount: notes.count,
                    unreadableNoteIDs: [],
                    request: request
                )
            }

            var matches: [Note] = []
            var unreadable: [Note.ID] = []
            var scanned = 0
            for note in candidates.prefix(request.scanLimit) where matches.count < request.limit {
                try checkBudget()
                scanned += 1
                switch try match(query, in: note) {
                case .some(true): matches.append(note)
                case .some(false): break
                case nil: unreadable.append(note.id)
                }
            }
            return Store.SearchResult(
                notes: matches,
                nextCursor: scanned < candidates.count ? Note.FetchRequest.Cursor(after: candidates[scanned - 1]) : nil,
                scannedNoteCount: scanned,
                unreadableNoteIDs: unreadable,
                request: request
            )
        }
    }

    /// Returns whether a note's title, preview, or contents contain the query,
    /// or `nil` if the title and preview don't and the contents can't be decoded.
    ///
    /// Locked notes match by title alone, because their contents are encrypted.
    /// Notes without contents on this Mac match by title and preview.
    private func match(_ query: String, in note: Note) throws -> Bool? {
        func matches(_ text: String?) -> Bool {
            text?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if matches(note.title) || matches(note.snippet) {
            return true
        }
        guard !note.isLocked else { return false }
        do {
            return matches(try content(of: note).searchableText)
        } catch NotesError.unsupportedContent, NotesError.malformedContent {
            return nil
        } catch NotesError.contentNotFound {
            return false
        }
    }
}
