import Foundation

/// Applies edits to the stored document of a note, and returns a new document for the same note.
///
/// The editor changes the text, the attribute runs, and the merge state together,
/// and leaves every other part of the document as it was.
/// It reads and returns bytes. It does not open a database.
///
/// An edit never deletes or splits an attachment, and it fails rather than guess:
/// see ``NoteEditError`` for the reasons.
/// When an edit fails, none of the edits of the call are applied.
struct NoteEditor: Sendable {
    /// The replica that the edits belong to.
    ///
    /// Notes tells editors apart by a UUID in the document's vector timestamp.
    /// The default is a new UUID for each editor, as a new session of the Notes web app takes one.
    /// A replica must never give one clock value to two different characters,
    /// so use an editor's replica again only for a document that holds its earlier edits.
    var replica: UUID
    /// Makes the identifier of a new checklist item.
    ///
    /// The stored form is the 16 bytes of a UUID.
    /// Notes doesn't derive the identifier from anything, so a random UUID serves.
    var makeIdentifier: @Sendable () -> UUID

    init(replica: UUID = UUID(), makeIdentifier: @escaping @Sendable () -> UUID = { UUID() }) {
        self.replica = replica
        self.makeIdentifier = makeIdentifier
    }

    /// Applies edits to the stored contents of a note.
    /// - Parameters:
    ///   - data: The contents of the note's row in `ZICNOTEDATA.ZDATA`.
    ///   - note: The note that the contents belong to.
    ///   - edits: The edits, which apply in order. Each one sees the note as the edits before it left it.
    /// - Returns: New contents for the same row. Edits that change nothing return contents with the same document.
    /// - Throws: ``NoteEditError/noteLocked(_:)`` for a locked note, before it reads the data,
    ///   or another ``NoteEditError`` that names why an edit was not made.
    func edit(_ data: Data, of note: Note, applying edits: [NoteEdit]) throws -> Data {
        guard !note.isLocked else {
            throw NoteEditError.noteLocked(note.id)
        }
        let stored: StoredNote
        do {
            stored = try StoredNote(data: data)
        } catch {
            throw NoteEditError.unreadableContent
        }
        return try apply(edits, to: stored).data()
    }

    /// Applies edits to a decoded document.
    func apply(_ edits: [NoteEdit], to stored: StoredNote) throws -> StoredNote {
        var note = stored
        for edit in edits {
            if let broken = note.brokenInvariants.first {
                throw NoteEditError.unsupportedDocument(broken)
            }
            try apply(edit, to: &note)
        }
        // An edit must leave the document as sound as it found it.
        if !edits.isEmpty, let broken = note.brokenInvariants.first {
            throw NoteEditError.unsupportedDocument(broken)
        }
        return note
    }

    private var replicaBytes: [UInt8] {
        withUnsafeBytes(of: replica.uuid) { Array($0) }
    }

    private func apply(_ edit: NoteEdit, to note: inout StoredNote) throws {
        switch edit {
        case .insertParagraphs(let paragraphs, let position):
            try insert(paragraphs, at: position, in: &note)
        case .insertText(let text, let position):
            let offset = try note.offset(of: position)
            try replace(offset ..< offset, with: text, in: &note)
        case .replaceText(let selection, let text):
            try replace(try note.range(of: selection), with: text, in: &note)
        case .deleteText(let selection):
            try replace(try note.range(of: selection), with: "", in: &note)
        case .deleteParagraphs(let first, let last):
            let paragraphs = note.paragraphRanges
            var lower = try note.paragraph(first)
            var upper = try last.map { try note.paragraph($0) } ?? lower
            if upper < lower {
                swap(&lower, &upper)
            }
            var range = paragraphs[lower].content.lowerBound ..< paragraphs[upper].full.upperBound
            // Without a line feed of its own, the last paragraph goes with the line feed before it,
            // so that no empty paragraph is left.
            if !paragraphs[upper].hasLineFeed, range.lowerBound > 0 {
                range = range.lowerBound - 1 ..< range.upperBound
            }
            try replace(range, with: "", in: &note)
        case .setChecked(let isChecked, let anchor):
            try setChecked(isChecked, at: anchor, in: &note)
        }
    }

    // MARK: Text

    /// Replaces a range of the text with text that has no line feed.
    ///
    /// New text takes the attributes of the text that it replaces.
    /// Inserted text takes the attributes of the character before it in its paragraph,
    /// or of the character after it at the start of a paragraph.
    /// Next to another run, as opposed to inside one, it does not take that run's link.
    private func replace(_ range: Range<Int>, with text: String, in note: inout StoredNote) throws {
        let units = Array(note.text.utf16)
        let inserted = Array(text.utf16)
        guard range.lowerBound >= 0, range.upperBound <= units.count else {
            throw NoteEditError.outOfBounds
        }
        for boundary in [range.lowerBound, range.upperBound] where boundary > 0 && boundary < units.count {
            if UTF16.isLeadSurrogate(units[boundary - 1]), UTF16.isTrailSurrogate(units[boundary]) {
                throw NoteEditError.splitsCharacter
            }
        }
        guard !inserted.contains(where: { $0 == 0x0A || $0 == 0x0D }) else {
            throw NoteEditError.lineFeedInText
        }
        guard !inserted.contains(0xFFFC) else {
            throw NoteEditError.attachmentCharacterInText
        }
        guard Array(units[range]) != inserted else { return }

        try note.checkNoAttachment(in: range)
        if range.isEmpty, note.isInsideAttachment(range.lowerBound) {
            throw NoteEditError.insideAttachment
        }

        // The paragraph that holds the start of the range: from the line feed before it to the next one.
        let paragraphStart = (units[..<range.lowerBound].lastIndex(of: 0x0A) ?? -1) + 1
        let paragraphEnd = units[range.lowerBound...].firstIndex(of: 0x0A) ?? units.count
        if !inserted.isEmpty, note.hasTable(in: paragraphStart ..< paragraphEnd) {
            throw NoteEditError.tableInParagraph
        }
        // A range with a line feed joins what is before it to what is after it.
        // That is safe only when one of the two is empty, and new text counts as what is before.
        if units[range].contains(0x0A), range.upperBound != units.count, range.lowerBound != paragraphStart || !inserted.isEmpty {
            throw NoteEditError.joinsParagraphs
        }

        var newRun: StoredNote.AttributeRun?
        if !inserted.isEmpty {
            let before = range.lowerBound > 0 ? note.run(at: range.lowerBound - 1)?.index : nil
            let at = range.lowerBound < units.count ? note.run(at: range.lowerBound)?.index : nil
            if !range.isEmpty, let at {
                newRun = note.runs[at]
            } else if let before, before == at {
                newRun = note.runs[before]
            } else if range.lowerBound > paragraphStart, let before {
                newRun = note.runs[before].copyForAdjacentText()
            } else if let at {
                newRun = note.runs[at].copyForAdjacentText()
            } else {
                // An empty paragraph at the end of the note has no character to take attributes from.
                newRun = StoredNote.AttributeRun(length: 0)
            }
            newRun?.length = inserted.count
        }

        var pass = note.beginPass(replica: replicaBytes)
        note.deleteVisible(range, pass: &pass)
        note.insertVisible(count: inserted.count, at: range.lowerBound, pass: &pass)
        note.endPass(pass)

        note.removeRuns(in: range)
        if let newRun {
            note.insertRuns([newRun], at: range.lowerBound)
        }
        note.text = String(decoding: units[..<range.lowerBound] + inserted + units[range.upperBound...], as: UTF16.self)
    }

    // MARK: Paragraphs

    private func insert(_ paragraphs: [NoteEdit.NewParagraph], at position: NoteEdit.ParagraphPosition, in note: inout StoredNote) throws {
        // Each line of a new paragraph is a paragraph of its own.
        let pieces = paragraphs.flatMap { paragraph in
            paragraph.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { (units: Array($0.utf16), paragraph: paragraph) }
        }
        guard !pieces.isEmpty else { return }
        guard !pieces.contains(where: { $0.units.contains(0xFFFC) }) else {
            throw NoteEditError.attachmentCharacterInText
        }

        let units = Array(note.text.utf16)
        let ranges = note.paragraphRanges
        let offset: Int
        switch position {
        case .end:
            offset = units.count
        case .before(let anchor):
            offset = ranges[try note.paragraph(anchor)].content.lowerBound
        case .after(let anchor):
            offset = ranges[try note.paragraph(anchor)].full.upperBound
        }
        if note.isInsideAttachment(offset) {
            throw NoteEditError.insideAttachment
        }

        // The writing direction of the paragraph before the new ones, or of the one after them.
        let neighbor = note.run(at: offset - 1)?.index ?? 0
        let direction = (note.runs[..<min(neighbor + 1, note.runs.count)].reversed() + note.runs.dropFirst(neighbor + 1))
            .lazy.compactMap { $0.paragraphStyle?.varint(3) }.first

        var inserted: [UInt16] = []
        var runs: [StoredNote.AttributeRun] = []
        var styled: [Range<Int>] = []
        let isAtEnd = offset == units.count
        if isAtEnd, let last = units.last, last != 0x0A {
            // The line feed that ends the last paragraph belongs to that paragraph, and takes its attributes.
            inserted.append(0x0A)
            if var run = note.run(at: units.count - 1).map({ note.runs[$0.index].copyForAdjacentText() }) {
                run.length = 1
                runs.append(run)
            }
        }
        for (index, piece) in pieces.enumerated() {
            // At the end of the note, the last new paragraph gets no line feed, as the last paragraph of a note has none.
            let hasLineFeed = !isAtEnd || index < pieces.count - 1
            let length = piece.units.count + (hasLineFeed ? 1 : 0)
            let start = offset + inserted.count
            inserted += piece.units + (hasLineFeed ? [0x0A] : [])
            if piece.paragraph.style != .body {
                guard length > 0 else {
                    throw NoteEditError.emptyParagraph
                }
                styled.append(start ..< start + length)
            }
            if length > 0 {
                runs.append(StoredNote.AttributeRun(length: length, paragraphStyle: paragraphStyle(for: piece.paragraph, writingDirection: direction)))
            }
        }

        var pass = note.beginPass(replica: replicaBytes)
        note.insertVisible(count: inserted.count, at: offset, pass: &pass)
        note.endPass(pass)
        // Inference: a list style on new text is a style operation, as it is when the Notes web app sets one.
        if !styled.isEmpty {
            var stylePass = note.beginPass(replica: replicaBytes)
            for range in styled {
                note.restampVisible(range, pass: &stylePass)
            }
            note.endPass(stylePass)
        }

        note.insertRuns(runs, at: offset)
        note.text = String(decoding: units[..<offset] + inserted + units[offset...], as: UTF16.self)
    }

    /// The paragraph style of a new paragraph.
    ///
    /// On macOS 27.0.1, 99 of 100 runs had a paragraph style, and half of the styles had no `style` [1],
    /// which is how Notes stores body text. Nine of ten styles had `writingDirection` [3].
    /// So a new paragraph gets a style with `style` [1] for a list, the writing direction of the nearest paragraph,
    /// and `todo` [5] for a checklist item.
    ///
    /// Inference: the nearest paragraph's writing direction is the right one for the new paragraph.
    /// Inference: the style needs no `uuid` [9], which 28 of 100 stored styles had; its meaning is not known.
    /// - Returns: The style, or `nil` for body text in a note that has no writing direction to take.
    private func paragraphStyle(for paragraph: NoteEdit.NewParagraph, writingDirection: UInt64?) -> WireMessage? {
        var fields: [WireMessage.Field] = []
        switch paragraph.style {
        case .body: break
        case .bulleted: fields.append(.init(1, .varint(100)))
        case .numbered: fields.append(.init(1, .varint(102)))
        case .checklist: fields.append(.init(1, .varint(103)))
        }
        if let writingDirection {
            fields.append(.init(3, .varint(writingDirection)))
        }
        if paragraph.style == .checklist {
            fields.append(.init(5, .bytes(newTodo(isChecked: paragraph.isChecked).encoded())))
        }
        return fields.isEmpty ? nil : WireMessage(fields)
    }

    /// A `Todo` message with a new identifier.
    private func newTodo(isChecked: Bool) -> WireMessage {
        let identifier = withUnsafeBytes(of: makeIdentifier().uuid) { Array($0) }
        return WireMessage([.init(1, .bytes(identifier)), .init(2, .varint(isChecked ? 1 : 0))])
    }

    // MARK: Checklists

    private func setChecked(_ isChecked: Bool, at anchor: NoteEdit.ParagraphAnchor, in note: inout StoredNote) throws {
        let range = note.paragraphRanges[try note.paragraph(anchor)].full
        // The run of a paragraph's first character sets its style.
        guard let first = note.run(at: range.lowerBound), note.runs[first.index].styleType == 103 else {
            throw NoteEditError.notChecklistItem
        }
        let done: UInt64 = isChecked ? 1 : 0
        func needsChange(_ run: StoredNote.AttributeRun) -> Bool {
            run.styleType == 103 && (run.todo?.varint(2) ?? 0) != done
        }
        let changes = note.runs(overlapping: range).contains(where: needsChange)
        guard changes else { return }

        // A run can cover more than the paragraph. Only the part in the paragraph changes.
        note.splitRun(at: range.lowerBound)
        note.splitRun(at: range.upperBound)
        var start = 0
        for index in note.runs.indices {
            let run = note.runs[index]
            defer { start += run.length }
            guard start >= range.lowerBound, start < range.upperBound, needsChange(run), var style = run.paragraphStyle else { continue }
            if var todo = run.todo {
                todo.setVarint(2, done)
                style.setMessage(5, todo)
            } else {
                style.setMessage(5, newTodo(isChecked: isChecked))
            }
            note.runs[index].paragraphStyle = style
        }

        var pass = note.beginPass(replica: replicaBytes)
        note.restampVisible(range, pass: &pass)
        note.endPass(pass)
    }
}

// MARK: - Anchors

extension StoredNote {
    /// The index of the paragraph that an anchor names.
    func paragraph(_ anchor: NoteEdit.ParagraphAnchor) throws -> Int {
        let ranges = paragraphRanges
        switch anchor {
        case .index(let index):
            guard ranges.indices.contains(index) else {
                throw NoteEditError.paragraphNotFound(anchor)
            }
            return index
        case .containing(let text):
            let matches = ranges.indices.filter { !occurrences(of: text, in: ranges[$0].content).isEmpty }
            guard let match = matches.first else {
                throw NoteEditError.paragraphNotFound(anchor)
            }
            guard matches.count == 1 else {
                throw NoteEditError.ambiguousParagraph(anchor, matches: matches.count)
            }
            return match
        }
    }

    /// The range of the text that a match names.
    func range(of match: NoteEdit.TextMatch) throws -> Range<Int> {
        let scope = try match.paragraph.map { paragraphRanges[try paragraph($0)].content } ?? 0 ..< length
        let found = occurrences(of: match.text, in: scope)
        guard !found.isEmpty else {
            throw NoteEditError.textNotFound(match.text)
        }
        if let occurrence = match.occurrence {
            guard occurrence >= 1, occurrence <= found.count else {
                throw NoteEditError.occurrenceNotFound(match.text, matches: found.count)
            }
            return found[occurrence - 1]
        }
        guard found.count == 1 else {
            throw NoteEditError.ambiguousText(match.text, matches: found.count)
        }
        return found[0]
    }

    func range(of selection: NoteEdit.TextSelection) throws -> Range<Int> {
        switch selection {
        case .match(let match):
            return try range(of: match)
        case .paragraphText(let anchor):
            return paragraphRanges[try paragraph(anchor)].content
        case .range(let range):
            return range
        }
    }

    func offset(of position: NoteEdit.TextPosition) throws -> Int {
        switch position {
        case .before(let match):
            return try range(of: match).lowerBound
        case .after(let match):
            return try range(of: match).upperBound
        case .startOfParagraph(let anchor):
            return paragraphRanges[try paragraph(anchor)].content.lowerBound
        case .endOfParagraph(let anchor):
            return paragraphRanges[try paragraph(anchor)].content.upperBound
        case .offset(let offset):
            return offset
        }
    }

    /// The ranges where text occurs in a range of the note's text, from first to last, without overlap.
    ///
    /// The comparison is exact but for the composition of characters:
    /// a letter with an accent matches whether it is stored as one character or as two.
    private func occurrences(of text: String, in scope: Range<Int>) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        let string = self.text as NSString
        var found: [Range<Int>] = []
        var start = scope.lowerBound
        while start < scope.upperBound {
            let match = string.range(of: text, options: [], range: NSRange(location: start, length: scope.upperBound - start))
            guard match.location != NSNotFound, match.length > 0 else { break }
            found.append(match.location ..< match.location + match.length)
            start = match.location + match.length
        }
        return found
    }
}

// MARK: - Attribute runs

extension StoredNote {
    /// The runs that cover at least one character of a range.
    fileprivate func runs(overlapping range: Range<Int>) -> [AttributeRun] {
        guard !range.isEmpty else { return [] }
        var start = 0
        var overlapping: [AttributeRun] = []
        for run in runs {
            if start < range.upperBound, start + run.length > range.lowerBound {
                overlapping.append(run)
            }
            start += run.length
        }
        return overlapping
    }

    /// Throws if a range holds a character of an attachment's run.
    fileprivate func checkNoAttachment(in range: Range<Int>) throws {
        guard let run = runs(overlapping: range).first(where: \.hasAttachment) else { return }
        throw run.attachmentType == Note.Attachment.tableType ? NoteEditError.tableInRange : .attachmentInRange(type: run.attachmentType)
    }

    /// Returns whether an offset is between two characters of one attachment's run.
    fileprivate func isInsideAttachment(_ offset: Int) -> Bool {
        guard offset > 0, let before = run(at: offset - 1), let at = run(at: offset), before.index == at.index else { return false }
        return runs[at.index].hasAttachment
    }

    /// Returns whether a range holds a table.
    fileprivate func hasTable(in range: Range<Int>) -> Bool {
        runs(overlapping: range).contains { $0.attachmentType == Note.Attachment.tableType }
    }

    /// Takes a range of characters out of the runs. A run that loses every character is removed.
    fileprivate mutating func removeRuns(in range: Range<Int>) {
        guard !range.isEmpty else { return }
        var start = 0
        var kept: [AttributeRun] = []
        for var run in runs {
            let end = start + run.length
            let overlap = max(0, min(end, range.upperBound) - max(start, range.lowerBound))
            start = end
            if overlap > 0 {
                guard overlap < run.length else { continue }
                run.length -= overlap
            }
            kept.append(run)
        }
        runs = kept
    }

    /// Splits the run that an offset falls inside, so that a run starts at the offset.
    /// - Returns: The index of the run that starts at the offset, or the number of runs for the end of the text.
    @discardableResult
    fileprivate mutating func splitRun(at offset: Int) -> Int {
        guard let (index, start) = run(at: offset) else { return runs.count }
        guard offset > start else { return index }
        var tail = runs[index]
        tail.length -= offset - start
        runs[index].length = offset - start
        runs.insert(tail, at: index + 1)
        return index + 1
    }

    /// Inserts runs at an offset, and joins them to a neighbor that has the same attributes,
    /// so that text which takes the attributes of its surroundings leaves one run, not three.
    fileprivate mutating func insertRuns(_ new: [AttributeRun], at offset: Int) {
        guard !new.isEmpty else { return }
        let index = splitRun(at: offset)
        runs.insert(contentsOf: new, at: index)
        for seam in [index + new.count, index] where seam > 0 && seam < runs.count {
            if runs[seam - 1].hasSameAttributes(as: runs[seam]) {
                runs[seam - 1].length += runs[seam].length
                runs.remove(at: seam)
            }
        }
    }
}
