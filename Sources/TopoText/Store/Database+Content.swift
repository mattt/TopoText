import Foundation

extension Database {
    /// Returns the contents of a note that Notes lists.
    /// - Throws: ``NotesError/noteNotFound(_:)``, ``NotesError/noteLocked(_:)``,
    ///   ``NotesError/contentNotFound(_:)``, ``NotesError/unsupportedContent(_:)``,
    ///   ``NotesError/malformedContent(_:)``, or another ``NotesError`` if the database can't be read.
    func content(for identifier: Note.ID) throws -> Note.Content {
        try readTransaction {
            try content(of: try note(for: identifier))
        }
    }

    /// Returns the contents of a note, with its attachments resolved.
    func content(of note: Note) throws -> Note.Content {
        guard !note.isLocked else {
            throw NotesError.noteLocked(note.id)
        }
        guard let data = try noteData(rowID: note.rowID), !data.isEmpty else {
            throw NotesError.contentNotFound(note.id)
        }
        let document: NoteDocument
        do {
            document = try NoteDocument(data: data)
        } catch FormatError.unrecognized {
            throw NotesError.unsupportedContent(note.id)
        } catch {
            throw NotesError.malformedContent(note.id)
        }
        var resolver = AttachmentResolver(loadRows: attachmentRows, checkBudget: checkBudget)
        return try resolver.content(of: document)
    }

    /// Returns the stored contents of a note.
    ///
    /// An edit can leave an older row behind, so this takes the newest one.
    func noteData(rowID: Int64) throws -> Data? {
        let sql: String
        if noteDataColumns.contains("ZNOTE") {
            sql = "SELECT ZDATA FROM ZICNOTEDATA WHERE ZNOTE = ? ORDER BY Z_PK DESC LIMIT 1"
        } else if columns.contains("ZNOTEDATA") {
            sql = """
                SELECT d.ZDATA FROM ZICNOTEDATA d JOIN ZICCLOUDSYNCINGOBJECT n ON d.Z_PK = n.ZNOTEDATA
                WHERE n.Z_PK = ? LIMIT 1
                """
        } else {
            throw NotesError.unsupportedSchema
        }
        return try query(sql, [.integer(rowID)]) { $0.blob(0) }.first ?? nil
    }

    /// The values of an attachment row, and the stored data of a table.
    struct AttachmentRow {
        var attachment: Note.Attachment
        var tableData: Data?
    }

    /// Returns the attachment rows with the identifiers, keyed by identifier.
    func attachmentRows(_ identifiers: Set<Note.Attachment.ID>) throws -> [Note.Attachment.ID: AttachmentRow] {
        var rows: [Note.Attachment.ID: AttachmentRow] = [:]
        let sorted = identifiers.map(\.description).sorted()
        // Stay well under SQLite's limit on the number of bound values.
        for start in stride(from: 0, to: sorted.count, by: 500) {
            let batch = sorted[start ..< min(start + 500, sorted.count)]
            let sql = """
                SELECT a.ZIDENTIFIER, \(coalesce("a", "ZTYPEUTI1", "ZTYPEUTI")), \(column("a", "ZALTTEXT")),
                    \(column("a", "ZTOKENCONTENTIDENTIFIER")), \(coalesce("a", "ZTITLE", "ZUSERTITLE")),
                    \(column("a", "ZURLSTRING")), \(column("m", "ZFILENAME")), \(column("a", "ZSUMMARY")),
                    \(column("a", "ZOCRSUMMARY")), \(column("a", "ZHANDWRITINGSUMMARY")),
                    CASE WHEN \(column("a", "ZTYPEUTI")) = '\(Note.Attachment.tableType)'
                        THEN \(coalesce("a", "ZMERGEABLEDATA1", "ZMERGEABLEDATA")) END
                FROM ZICCLOUDSYNCINGOBJECT a
                LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = \(column("a", "ZMEDIA"))
                WHERE a.ZIDENTIFIER IN (\(placeholders(batch.count)))
                """
            try query(sql, batch.map { .text($0) }) { row in
                guard let identifier = row.text(0).flatMap(Note.Attachment.ID.init(_:)) else { return }
                let attachment = Note.Attachment(
                    id: identifier,
                    typeIdentifier: row.text(1),
                    displayText: row.text(2),
                    tokenIdentifier: row.text(3),
                    title: row.text(4),
                    url: row.text(5).flatMap(URL.init(string:)),
                    fileName: row.text(6),
                    summary: row.text(7),
                    recognizedText: row.text(8),
                    handwritingText: row.text(9)
                )
                // Should another kind of row share the identifier, keep the one that has a type.
                if rows[identifier]?.attachment.typeIdentifier == nil || attachment.typeIdentifier != nil {
                    rows[identifier] = AttachmentRow(attachment: attachment, tableData: row.blob(10))
                }
            }
        }
        return rows
    }
}

/// Resolves the attachments of a note's contents, including those in table cells.
///
/// The resolver reads the attachments of each level of nesting in one query,
/// and remembers the rows and tables it has read.
/// Tables can hold attachments, including other tables.
/// A table inside itself is not decoded again,
/// and tables nested deeper than ``maximumDepth`` are not decoded.
struct AttachmentResolver {
    /// The deepest nesting of tables that the resolver decodes.
    static let maximumDepth = 4

    /// Reads the rows of attachments, keyed by identifier.
    private let loadRows: (Set<Note.Attachment.ID>) throws -> [Note.Attachment.ID: Database.AttachmentRow]
    /// Throws if the work should stop, such as at a time limit.
    private let checkBudget: () throws -> Void
    private var rows: [Note.Attachment.ID: Database.AttachmentRow] = [:]
    private var lookedUp: Set<Note.Attachment.ID> = []
    /// Decoded tables, or `nil` for tables that can't be decoded.
    private var tables: [Note.Attachment.ID: TableDocument?] = [:]
    /// The tables that contain the one being resolved.
    private var enclosingTables: Set<Note.Attachment.ID> = []

    /// Creates a resolver that reads attachment rows with a function.
    /// - Parameters:
    ///   - loadRows: A function that returns the rows of attachments, keyed by identifier.
    ///   - checkBudget: A function that throws if the work should stop. The resolver calls it for each table.
    init(
        loadRows: @escaping (Set<Note.Attachment.ID>) throws -> [Note.Attachment.ID: Database.AttachmentRow],
        checkBudget: @escaping () throws -> Void = {}
    ) {
        self.loadRows = loadRows
        self.checkBudget = checkBudget
    }

    /// Returns contents with resolved attachments for a decoded document.
    mutating func content(of document: NoteDocument, depth: Int = 0) throws -> Note.Content {
        try load(document.attachments.map(\.identifier))

        var paragraphs: [Note.Paragraph] = []
        for paragraph in document.paragraphs {
            var runs: [Note.TextRun] = []
            for segment in paragraph.segments {
                var run = segment.run.format
                run.text = segment.text
                if let reference = segment.run.attachment {
                    run.attachment = try attachment(for: reference, depth: depth)
                }
                runs.append(run)
            }
            paragraphs.append(Note.Paragraph(style: paragraph.style ?? Note.ParagraphStyle(), runs: runs))
        }
        return Note.Content(paragraphs: paragraphs)
    }

    /// Returns the attachment that a run refers to.
    ///
    /// If the database has no row for it, the attachment has the identifier and type from the reference.
    /// If a table can't be decoded, its ``Note/Attachment/table`` is `nil`.
    private mutating func attachment(for reference: NoteDocument.AttachmentReference, depth: Int) throws -> Note.Attachment {
        let row = rows[reference.identifier]
        var attachment = row?.attachment ?? Note.Attachment(id: reference.identifier)
        if attachment.typeIdentifier == nil {
            attachment.typeIdentifier = reference.typeIdentifier
        }
        guard attachment.kind == .table, depth < Self.maximumDepth, !enclosingTables.contains(attachment.id),
            let table = try decodedTable(attachment.id)
        else { return attachment }

        enclosingTables.insert(attachment.id)
        defer { enclosingTables.remove(attachment.id) }
        try load(table.rows.flatMap { $0.flatMap { $0?.attachments.map(\.identifier) ?? [] } })
        var rows: [[Note.Content]] = []
        for cells in table.rows {
            var row: [Note.Content] = []
            for cell in cells {
                row.append(try cell.map { try content(of: $0, depth: depth + 1) } ?? Note.Content())
            }
            rows.append(row)
        }
        attachment.table = Note.Table(rows: rows, isRightToLeft: table.isRightToLeft)
        return attachment
    }

    /// Returns the decoded table of an attachment, or `nil` if it has no table data or the data can't be decoded.
    private mutating func decodedTable(_ identifier: Note.Attachment.ID) throws -> TableDocument? {
        try checkBudget()
        if let table = tables[identifier] {
            return table
        }
        let table = rows[identifier]?.tableData.flatMap { try? TableDocument(data: $0) }
        tables[identifier] = table
        return table
    }

    /// Reads the rows of attachments that the resolver has not looked up yet.
    private mutating func load(_ identifiers: [Note.Attachment.ID]) throws {
        let missing = Set(identifiers).subtracting(lookedUp)
        guard !missing.isEmpty else { return }
        lookedUp.formUnion(missing)
        rows.merge(try loadRows(missing)) { $1 }
    }
}
