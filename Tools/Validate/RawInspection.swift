// This file uses TopoText's internal decoders, which only a debug build makes available to `@testable import`,
// so a release build of the tool leaves it out. `swift run Validate` builds for debugging.
#if DEBUG
    import Foundation
    import SQLite3
    @testable import TopoText

    /// Counts the stored values behind the decoded contents: protocol buffer fields, style values that
    /// TopoText doesn't recognize, and how titles relate to the text.
    ///
    /// Like the rest of the tool, it prints only counts and numbers that the format defines,
    /// never text, titles, identifiers, or file names.
    func inspectStoredContents(root: URL) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        func add(_ label: String, _ amount: Int = 1) {
            counts[label, default: 0] += amount
        }

        let database = try Database(root: root, timeLimit: .seconds(600))
        defer { database.close() }
        try database.readTransaction {
            var cursor: Note.FetchRequest.Cursor?
            repeat {
                let result = try database.search(.init(includesRecentlyDeleted: true, limit: Note.FetchRequest.maximumLimit, cursor: cursor))
                for note in result.notes where !note.isLocked {
                    guard let data = try database.noteData(rowID: note.rowID),
                        let message = try? ProtobufMessage(data.gunzipped()).message(2)?.message(3)
                    else {
                        add("stored: notes without contents that decode")
                        continue
                    }
                    inspectRuns(of: message, add: add)
                    inspectStoredDocument(data, add: add)
                    let content = try database.content(of: note)
                    let category = titleCategory(title: note.title, content: content)
                    add("titles: \(category)")
                    if category.hasPrefix("not found") {
                        inspectUnmatchedTitle(note: note, content: content, add: add)
                    }
                    try inspectRows(of: note, category: category, database: database, add: add)
                    try inspectScans(in: content, database: database, add: add)
                }
                cursor = result.nextCursor
            } while cursor != nil
            try inspectLinkRows(database: database, add: add)
        }
        return counts
    }

    /// Counts what the rows of inline links to notes hold, for every note, without identifiers or text.
    ///
    /// For each row it counts the columns that have a value.
    /// For a column whose name suggests a token, an identifier, or a URL, it also counts the form of the value,
    /// with each identifier replaced by its length and kind.
    private func inspectLinkRows(database: Database, add: (String, Int) -> Void) throws {
        guard let entity = database.entities["ICInlineAttachment"] else { return }
        let type = database.coalesce("i", "ZTYPEUTI1", "ZTYPEUTI")
        let sql = "SELECT i.* FROM ZICCLOUDSYNCINGOBJECT i WHERE i.Z_ENT = ? AND \(type) = ?"
        try database.query(sql, [.integer(entity), .text(Database.noteLinkType)]) { row in
            add("link rows", 1)
            for index in 0 ..< sqlite3_column_count(row.statement) {
                guard let name = sqlite3_column_name(row.statement, index).map({ String(cString: $0) }) else { continue }
                switch sqlite3_column_type(row.statement, index) {
                case SQLITE_NULL:
                    continue
                case SQLITE_INTEGER, SQLITE_FLOAT:
                    if row.double(index) != 0 { add("link rows: \(name) holds a number other than 0", 1) }
                case SQLITE_TEXT:
                    add("link rows: \(name) holds text", 1)
                    if ["TOKEN", "IDENTIFIER", "URL"].contains(where: name.contains), !name.contains("UTI") {
                        add("link rows: \(name) of the form \(maskedShape(row.text(index)))", 1)
                    }
                default:
                    add("link rows: \(name) holds data", 1)
                }
            }
        }
    }

    /// Checks what the edit engine assumes about a note's stored document, without changing anything.
    ///
    /// It decodes the whole document, encodes it, and compares the bytes.
    /// It counts each invariant that the document lacks, and the forms of the merge state.
    /// For a document with every invariant, it applies an edit in memory and checks the result.
    /// The edit is never written anywhere.
    /// Like the rest of the tool, it prints only counts and numbers that the format defines.
    private func inspectStoredDocument(_ data: Data, add: (String, Int) -> Void) {
        func bucket(_ count: Int) -> String {
            count <= 3 ? "\(count)" : count <= 10 ? "4 to 10" : count <= 100 ? "11 to 100" : "over 100"
        }
        // The header's flags and operating system byte, which the gzip writer sets to 0 and 19.
        if data.count > 9 {
            add("gzip: flags \(data[data.startIndex + 3]), operating system byte \(data[data.startIndex + 9])", 1)
        }
        guard let protobuf = (try? data.gunzipped()).map(Array.init), let stored = try? StoredNote(protobuf: protobuf) else {
            add("lossless: notes that don't decode as a stored document", 1)
            return
        }
        add("lossless: notes decoded", 1)
        add("lossless: encoding \(stored.protobuf() == protobuf ? "equals" : "differs from") the stored bytes", 1)
        let canonical = (try? WireMessage(protobuf))?.reencoded(as: StoredNote.schema)
        add("lossless: stored bytes \(canonical == protobuf ? "are" : "are not") in the canonical form", 1)
        let recompressed = try? stored.data().gunzipped()
        add("lossless: compressing and decompressing \(recompressed == Data(protobuf) ? "gives" : "does not give") the same bytes", 1)

        let broken = stored.brokenInvariants
        add(broken.isEmpty ? "invariants: notes with every invariant" : "invariants: notes without at least one", 1)
        for invariant in broken {
            add("invariants: not true that \(invariant.rawValue)", 1)
        }

        // The fields of each message of the merge state, to find any that the format notes don't name.
        if let document = try? WireMessage(protobuf), let version = document.message(2), let string = version.message(3) {
            for number in Set(document.fields.map(\.number)) { add("merge state: Document field \(number)", 1) }
            for number in Set(version.fields.map(\.number)) { add("merge state: Version field \(number)", 1) }
            for number in Set(string.fields.map(\.number)) { add("merge state: String field \(number)", 1) }
            add("merge state: minimumSupportedVersion \(version.varint(2).map(String.init) ?? "absent")", 1)
        }
        add("merge state: notes with \(bucket(stored.replicas.count)) replicas", 1)
        add("merge state: notes with \(bucket(stored.substrings.count)) substrings", 1)
        for replica in stored.replicas {
            add("merge state: replicas with \(replica.clocks.count) clocks", 1)
            for number in Set(replica.message.fields.map(\.number)) { add("merge state: Clock field \(number)", 1) }
        }
        if let first = stored.substrings.first {
            let isOrigin = first.id == .init(replica: 0, clock: 0) && first.length == 0
            add("merge state: first substring \(isOrigin ? "is" : "is not") the empty one with the identifier (0, 0)", 1)
        }
        if let last = stored.substrings.last, last.isEnd {
            let timestamp = last.styleTimestamp
            let clock = timestamp.clock == StoredNote.Substring.endClock ? "the end clock" : "\(timestamp.clock == 0 ? "0" : "another clock")"
            add("merge state: end marker with the style timestamp (\(timestamp.replica == 0 ? "0" : "a replica"), \(clock))", 1)
        }
        for substring in stored.substrings {
            for number in Set(substring.message.fields.map(\.number)) { add("merge state: Substring field \(number)", 1) }
            if substring.isTombstone { add("merge state: substrings with a tombstone of \(substring.tombstoneValue)", 1) }
            if substring.children.count > 1 { add("merge state: substrings with more than one child", 1) }
            if substring.message.values(5).contains(where: { if case .bytes = $0 { true } else { false } }) {
                add("merge state: substrings with packed children", 1)
            }
            if !substring.isEnd, substring.id.replica != 0 {
                add("merge state: substrings with a style clock of \(substring.styleTimestamp.clock == 0 ? "0" : "more than 0")", 1)
            }
        }

        // Checklist identifiers: their length, their UUID version, and whether two paragraphs share one.
        var paragraphsByItem: [[UInt8]: Set<Int>] = [:]
        let starts = stored.paragraphRanges.map(\.content.lowerBound)
        var offset = 0
        for run in stored.runs {
            defer { offset += max(0, run.length) }
            if run.hasAttachment, run.length != 1 { add("runs: attachment runs with a length of \(bucket(run.length))", 1) }
            if let identifier = run.paragraphStyle?.bytes(9) { add("runs: paragraph style field 9 of \(identifier.count) bytes", 1) }
            guard let todo = run.todo else {
                if run.styleType == 103 { add("checklists: runs with the checklist style and no state", 1) }
                continue
            }
            let identifier = todo.bytes(1) ?? []
            add("checklists: identifiers of \(identifier.count) bytes, UUID version \(identifier.count == 16 ? "\(identifier[6] >> 4)" : "none")", 1)
            add("checklists: done value \(todo.varint(2).map(String.init) ?? "absent")", 1)
            for position in offset ..< offset + max(0, run.length) {
                paragraphsByItem[identifier, default: []].insert(starts.lastIndex { $0 <= position } ?? 0)
            }
        }
        for paragraphs in paragraphsByItem.values {
            add("checklists: identifiers in \(paragraphs.count == 1 ? "1 paragraph" : "more than 1 paragraph")", 1)
        }

        // An edit in memory: append a checklist item, then check that the result is sound and that the reader reads it.
        guard broken.isEmpty else { return }
        do {
            let edited = try NoteEditor().apply([.appendParagraphs([.init("x", style: .checklist)])], to: stored)
            let reread = try StoredNote(data: try edited.data())
            let readerText = try NoteDocument(data: try edited.data()).text
            let prefix = Array(stored.text.utf16)
            let isSound =
                reread.brokenInvariants.isEmpty && Array(reread.text.utf16.prefix(prefix.count)) == prefix
                && Array(reread.substrings.prefix(max(0, stored.substrings.count - 2))) == Array(stored.substrings.dropLast(2))
                && readerText == reread.text
            add("trial edit in memory: \(isSound ? "sound" : "not sound")", 1)
        } catch let error as NoteEditError {
            if case .unsupportedDocument = error {
                add("trial edit in memory: refused, unsupported document", 1)
            } else {
                add("trial edit in memory: refused for another reason", 1)
            }
        } catch {
            add("trial edit in memory: failed", 1)
        }
    }

    /// Counts the fields and values of a note's attribute runs.
    private func inspectRuns(of message: ProtobufMessage, add: (String, Int) -> Void) {
        let text = (message.string(2) ?? "") as NSString
        let runs = message.messages(5)
        let covered = runs.reduce(0) { $0 + max(0, $1.int32(1) ?? 0) }
        switch covered - text.length {
        case 0: add("stored: runs that cover the text exactly", 1)
        case ..<0: add("stored: runs that end before the text", 1)
        default: add("stored: runs that run past the text", 1)
        }

        var offset = 0
        for run in runs {
            for number in Set(run.fieldNumbers) {
                add("stored: AttributeRun field \(number)", 1)
            }
            if let style = run.message(2) {
                for number in Set(style.fieldNumbers) {
                    add("stored: ParagraphStyle field \(number)", 1)
                }
                if let type = style.int32(1), Note.ParagraphStyle.Kind(styleType: type) == nil {
                    add("stored: unrecognized style_type \(type)", 1)
                }
                if let alignment = style.int32(2) {
                    add("stored: alignment \(alignment)", 1)
                }
            }
            if let weight = run.int32(5), !(0 ... 3).contains(weight) {
                add("stored: unrecognized font_weight \(weight)", 1)
            }
            if let emphasis = run.int32(14), Note.TextRun.Highlight(emphasisStyle: emphasis) == nil {
                add("stored: unrecognized emphasis_style \(emphasis)", 1)
            }

            let length = max(0, min(run.int32(1) ?? 0, text.length - offset))
            let slice = length > 0 ? text.substring(with: NSRange(location: offset, length: length)) : ""
            offset += length
            let replacements = slice.utf16.filter { $0 == 0xFFFC }.count
            guard replacements > 0 else { continue }
            if let info = run.message(12) {
                if info.string(1)?.isEmpty ?? true { add("U+FFFC: attachment info without an identifier", 1) }
                if replacements > 1 { add("U+FFFC: attachment runs with more than one", 1) }
            } else {
                let fields = Set(run.fieldNumbers).sorted().map(String.init).joined(separator: ",")
                add("U+FFFC: runs without attachment info, with fields \(fields)", 1)
                add("U+FFFC: runs without attachment info, of length \(length == 1 ? "1" : "more than 1")", 1)
            }
        }
    }

    /// Describes how a note's title relates to its text, from the closest relation to the farthest.
    private func titleCategory(title: String, content: Note.Content) -> String {
        func collapsed(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        func plain(_ paragraph: Note.Paragraph, attachmentText: Bool) -> String {
            paragraph.runs.map { run in
                guard let attachment = run.attachment else { return run.text.replacingOccurrences(of: "\u{FFFC}", with: "") }
                return attachmentText ? (attachment.displayText ?? attachment.title ?? "") : ""
            }.joined()
        }

        let paragraphs = content.paragraphs
        let first = paragraphs.first.map { plain($0, attachmentText: false) } ?? ""
        let firstWithAttachments = paragraphs.first.map { plain($0, attachmentText: true) } ?? ""
        let firstNonEmpty = paragraphs.lazy.map { collapsed(plain($0, attachmentText: true)) }.first { !$0.isEmpty } ?? ""
        let normalizedTitle = collapsed(title)
        let line = collapsed(firstWithAttachments)

        if first.trimmingCharacters(in: .whitespacesAndNewlines) == title.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "same as the first line"
        }
        if collapsed(first) == normalizedTitle { return "same as the first line after collapsing white space" }
        if line == normalizedTitle { return "same as the first line with attachment text" }
        if firstNonEmpty == normalizedTitle { return "same as the first paragraph with text" }
        if normalizedTitle.isEmpty { return "empty" }
        if line.hasPrefix(normalizedTitle) { return "a prefix of the first line" }
        if firstNonEmpty.hasPrefix(normalizedTitle) { return "a prefix of the first paragraph with text" }
        if !line.isEmpty, normalizedTitle.hasPrefix(line) { return "longer than the first line, which it starts with" }
        if line.compare(normalizedTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return "same as the first line without regard to case or diacritics"
        }
        let lines = paragraphs.map { collapsed(plain($0, attachmentText: true)) }
        if lines.contains(normalizedTitle) { return "same as a later paragraph" }
        if collapsed(lines.joined(separator: " ")).contains(normalizedTitle) { return "found in the text" }
        let length = normalizedTitle.count
        let bucket = length <= 10 ? "up to 10" : length <= 40 ? "11 to 40" : length <= 100 ? "41 to 100" : "over 100"
        return "not found in the text, \(bucket) characters, first line \(line.isEmpty ? "empty" : "not empty")"
    }

    /// Counts the scanned documents whose files are found, by their type, which is one of three constants.
    private func inspectScans(in content: Note.Content, database: Database, add: (String, Int) -> Void) throws {
        for run in content.paragraphs.flatMap(\.runs) {
            guard let attachment = run.attachment else { continue }
            if attachment.kind == .scannedDocument {
                let found = Database.firstFile(in: try database.fileCandidates(for: attachment.id), root: database.root) != nil
                add("scans: \(attachment.typeIdentifier ?? "no type") \(found ? "found" : "not found")", 1)
            }
            for cell in attachment.table?.rows.flatMap({ $0 }) ?? [] {
                try inspectScans(in: cell, database: database, add: add)
            }
        }
    }

    /// Counts the contents rows of a note, and whether `ZNOTEDATA` points to the row that TopoText reads.
    private func inspectRows(of note: Note, category: String, database: Database, add: (String, Int) -> Void) throws {
        let rows = try database.query("SELECT Z_PK FROM ZICNOTEDATA WHERE ZNOTE = ? ORDER BY Z_PK DESC", [.integer(note.rowID)]) {
            $0.integer(0)
        }
        add("rows: notes with \(rows.count == 1 ? "1 contents row" : rows.count == 0 ? "no contents row" : "more than 1 contents row")", 1)
        let matched = !category.hasPrefix("not found")
        guard database.columns.contains("ZNOTEDATA") else {
            add("rows: no ZNOTEDATA column", 1)
            return
        }
        let pointer =
            try database.query("SELECT ZNOTEDATA FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?", [.integer(note.rowID)]) {
                $0.integer(0)
            }.first ?? nil
        guard let pointer else {
            add("rows: ZNOTEDATA is NULL, title \(matched ? "explained" : "not found")", 1)
            return
        }
        if pointer == rows.first ?? nil {
            add("rows: ZNOTEDATA is the newest row, title \(matched ? "explained" : "not found")", 1)
            return
        }
        add("rows: ZNOTEDATA is another row, title \(matched ? "explained" : "not found")", 1)
        // Read the row that ZNOTEDATA points to, and see how the title relates to its text.
        let data = try database.query("SELECT ZDATA FROM ZICNOTEDATA WHERE Z_PK = ?", [.integer(pointer)]) { $0.blob(0) }.first ?? nil
        guard let data, let document = try? NoteDocument(data: data) else {
            add("rows: the ZNOTEDATA row doesn't decode", 1)
            return
        }
        var resolver = AttachmentResolver(loadRows: database.attachmentRows)
        let content = try resolver.content(of: document)
        add("rows: with the ZNOTEDATA row, titles \(titleCategory(title: note.title, content: content))", 1)
    }

    /// Counts possible reasons that a title doesn't appear in the text of its note.
    private func inspectUnmatchedTitle(note: Note, content: Note.Content, add: (String, Int) -> Void) {
        /// The text without format characters, such as zero-width spaces, and with white space collapsed.
        func cleaned(_ text: String) -> String {
            let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            return visible.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let paragraphs = content.paragraphs.map { paragraph in
            cleaned(
                paragraph.runs.map { run in
                    run.attachment.map { $0.displayText ?? $0.title ?? "" } ?? run.text.replacingOccurrences(of: "\u{FFFC}", with: "")
                }.joined()
            )
        }
        let text = paragraphs.joined(separator: " ")
        let title = cleaned(note.title)
        let firstLine = paragraphs.first { !$0.isEmpty } ?? ""

        if text.contains(title) {
            add("unmatched titles: found without format characters", 1)
            return
        }
        for suffix in ["…", "..."] where title.hasSuffix(suffix) {
            let stem = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            add(
                "unmatched titles: end with an ellipsis, \(firstLine.hasPrefix(stem) ? "the rest starts the first line" : "the rest doesn't start the first line")",
                1
            )
        }
        let common = zip(title, firstLine).prefix { $0 == $1 }.count
        let share = title.isEmpty ? 0 : Double(common) / Double(title.count)
        add("unmatched titles: share a prefix with the first line of \(share == 0 ? "0" : share < 0.5 ? "under half" : "half or more") of the title", 1)
        if let snippet = note.snippet.map(cleaned), !snippet.isEmpty {
            let prefix = String(snippet.prefix(30))
            add("unmatched titles: preview \(text.contains(prefix) ? "found" : "not found") in the text", 1)
        } else {
            add("unmatched titles: no preview", 1)
        }
        let size = content.paragraphs.count < 3 ? "fewer than 3 paragraphs" : "3 or more paragraphs"
        add("unmatched titles: notes with \(size)", 1)
    }
#endif
