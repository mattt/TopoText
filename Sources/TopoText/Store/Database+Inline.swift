import Foundation

extension Database {
    /// The type of the inline attachments that are tags.
    static let hashtagType = "com.apple.notes.inlinetextattachment.hashtag"
    /// The type of the inline attachments that link to other notes.
    static let noteLinkType = "com.apple.notes.inlinetextattachment.link"

    // MARK: Smart folders

    /// Returns the smart folders, ordered by account name, then by name.
    func smartFolders() throws -> [SmartFolder] {
        let sql = """
            SELECT f.ZIDENTIFIER, \(column("f", "ZTITLE2")), p.ZIDENTIFIER, a.ZIDENTIFIER, \(column("a", "ZNAME")),
                \(column("f", "ZSMARTFOLDERQUERYJSON"))
            FROM ZICCLOUDSYNCINGOBJECT f
            LEFT JOIN ZICCLOUDSYNCINGOBJECT p ON p.Z_PK = \(column("f", "ZPARENT"))
            LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = \(column("f", "ZOWNER"))
            WHERE f.Z_ENT = \(try entity("ICFolder")) AND f.ZIDENTIFIER IS NOT NULL AND \(notMarkedForDeletion("f"))
                AND COALESCE(LENGTH(\(column("f", "ZSMARTFOLDERQUERYJSON"))), 0) > 0
                AND COALESCE(\(column("f", "ZNEEDSINITIALFETCHFROMCLOUD")), 0) = 0
            """
        let folders = try query(sql) { row -> SmartFolder? in
            guard let id = row.text(0).flatMap(SmartFolder.ID.init(_:)), let query = row.text(5) else { return nil }
            return SmartFolder(
                id: id,
                name: row.text(1) ?? "",
                parentID: row.text(2).flatMap(Folder.ID.init(_:)),
                account: row.text(3).flatMap(Account.ID.init(_:)).map { Account(id: $0, name: row.text(4)) },
                query: query
            )
        }
        return folders.compactMap { $0 }.sorted {
            ($0.account?.name?.lowercased() ?? "", $0.name.lowercased(), $0.id.description)
                < ($1.account?.name?.lowercased() ?? "", $1.name.lowercased(), $1.id.description)
        }
    }

    // MARK: Inline attachments

    /// A use of an inline attachment of one type in a note.
    struct InlineUse {
        let noteID: Note.ID
        let text: String?
        let token: String?
    }

    /// Returns the uses of inline attachments of a type in the notes that Notes lists.
    ///
    /// Locked notes are left out, because their contents are encrypted,
    /// and so are uses that are marked for deletion.
    /// Notes in Recently Deleted are left out unless `includingRecentlyDeleted` is set.
    /// A use whose attachment Notes has removed from the text can remain in the database for a while.
    /// - Parameters:
    ///   - type: The type identifier of the inline attachment.
    ///   - noteIDs: The notes to read, or `nil` for every note.
    ///   - target: A note whose identifier the use's token must contain, or `nil` for any token.
    ///     The condition narrows the rows in SQL; the caller still parses each token.
    ///   - includingRecentlyDeleted: Whether notes in Recently Deleted count.
    /// - Throws: ``NotesError/unsupportedSchema`` if the database has inline attachments
    ///   but no column that marks locked notes; ``NotesError/connectionClosed``;
    ///   or another ``NotesError`` if the database can't be read.
    func inlineUses(
        of type: String,
        in noteIDs: [Note.ID]? = nil,
        mentioning target: Note.ID? = nil,
        includingRecentlyDeleted: Bool = false
    ) throws -> [InlineUse] {
        try checkOpen()
        guard let entity = entities["ICInlineAttachment"] else { return [] }
        // Without the lock column, a locked note can't be told apart, and its rows must not be read.
        guard columns.contains("ZISPASSWORDPROTECTED") else { throw NotesError.unsupportedSchema }
        let notePK = coalesce("i", "ZNOTE1", "ZNOTE")
        var conditions = [
            "i.Z_ENT = ?",
            "\(coalesce("i", "ZTYPEUTI1", "ZTYPEUTI")) = ?",
            notMarkedForDeletion("i"),
            try isListedNote("n"),
            "COALESCE(n.ZISPASSWORDPROTECTED, 0) = 0",
        ]
        var bindings: [Binding] = [.integer(entity), .text(type)]
        if !includingRecentlyDeleted {
            conditions.append("NOT \(isRecentlyDeleted("f"))")
        }
        if let target {
            // LIKE ignores the case of ASCII letters, as links can carry the identifier in lowercase.
            conditions.append("\(column("i", "ZTOKENCONTENTIDENTIFIER")) LIKE ? ESCAPE '\\'")
            bindings.append(.text("%note/\(Self.escapedForLike(target.description))%"))
        }
        let select = """
            SELECT n.ZIDENTIFIER, \(column("i", "ZALTTEXT")), \(column("i", "ZTOKENCONTENTIDENTIFIER")), \(sortColumn)
            FROM ZICCLOUDSYNCINGOBJECT i
            JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = \(notePK)
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = \(column("n", "ZFOLDER"))
            """
        let transform: (Row) -> InlineUse? = { row in
            row.text(0).flatMap(Note.ID.init(_:)).map { InlineUse(noteID: $0, text: row.text(1), token: row.text(2)) }
        }
        let order = "ORDER BY \(sortColumn) DESC, n.Z_PK DESC, i.Z_PK"
        guard let noteIDs else {
            let sql = "\(select) WHERE \(conditions.joined(separator: " AND ")) \(order)"
            return try query(sql, bindings, transform: transform).compactMap { $0 }
        }
        var uses: [InlineUse] = []
        let identifiers = Set(noteIDs.map(\.description)).sorted()
        // Stay well under SQLite's limit on the number of bound values.
        for start in stride(from: 0, to: identifiers.count, by: 500) {
            let batch = identifiers[start ..< min(start + 500, identifiers.count)]
            let sql = """
                \(select) WHERE \(conditions.joined(separator: " AND ")) AND n.ZIDENTIFIER IN (\(placeholders(batch.count)))
                \(order)
                """
            uses += try query(sql, bindings + batch.map { .text($0) }, transform: transform).compactMap { $0 }
        }
        return uses
    }

    /// Escapes the characters that have a meaning in a LIKE pattern, with a backslash.
    static func escapedForLike(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// The expression that orders uses by the modification date of their note.
    private var sortColumn: String {
        "COALESCE(\(column("n", "ZMODIFICATIONDATE1")), \(Note.missingDateKey))"
    }

    // MARK: Tags

    /// Returns the tags of notes, in the order of the database's rows, without repeats within a note.
    func tags(for noteIDs: [Note.ID]) throws -> [Note.ID: [Note.Tag]] {
        var result: [Note.ID: [Note.Tag]] = [:]
        var seen: [Note.ID: Set<String>] = [:]
        for use in try inlineUses(of: Self.hashtagType, in: noteIDs) {
            guard let tag = use.text.flatMap(Note.Tag.init(_:)), seen[use.noteID, default: []].insert(tag.key).inserted else { continue }
            result[use.noteID, default: []].append(tag)
        }
        return result
    }

    /// Returns each tag with the number of notes that have it, most used first, then by name.
    func tagSummaries(includingRecentlyDeleted: Bool) throws -> [TagSummary] {
        struct Tally {
            var tag: Note.Tag
            var notes: Set<Note.ID> = []
        }
        var tallies: [String: Tally] = [:]
        // Uses come newest note first, so a tag keeps the spelling of the most recently edited note.
        for use in try inlineUses(of: Self.hashtagType, includingRecentlyDeleted: includingRecentlyDeleted) {
            guard let tag = use.text.flatMap(Note.Tag.init(_:)) else { continue }
            tallies[tag.key, default: Tally(tag: tag)].notes.insert(use.noteID)
        }
        return tallies.values.map { TagSummary(tag: $0.tag, noteCount: $0.notes.count) }.sorted {
            ($1.noteCount, $0.tag.key, $0.tag.name) < ($0.noteCount, $1.tag.key, $1.tag.name)
        }
    }

    // MARK: Note links

    /// Returns the links from notes to other notes, in the order of the database's rows.
    func links(from noteIDs: [Note.ID]) throws -> [Note.ID: [Note.Link]] {
        var result: [Note.ID: [Note.Link]] = [:]
        for use in try inlineUses(of: Self.noteLinkType, in: noteIDs) {
            guard let link = link(use) else { continue }
            result[use.noteID, default: []].append(link)
        }
        return result
    }

    /// Returns the links to a note from other notes that Notes lists, newest source note first.
    ///
    /// A link from a note to itself is left out.
    func backlinks(to target: Note.ID) throws -> [Note.Link] {
        try inlineUses(of: Self.noteLinkType, mentioning: target).compactMap(link).filter { $0.targetID == target && $0.sourceID != target }
    }

    private func link(_ use: InlineUse) -> Note.Link? {
        guard let target = use.token.flatMap(noteID(inLink:)) else { return nil }
        return Note.Link(sourceID: use.noteID, targetID: target, label: use.text)
    }
}
