// This file uses TopoText's internal decoders, which only a debug build makes available to `@testable import`,
// so a release build of the tool leaves it out. `swift run Validate` builds for debugging.
#if DEBUG
    import Foundation
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
        }
        return counts
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
