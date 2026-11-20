// This file uses TopoText's internal decoders, which only a debug build makes available to `@testable import`,
// so a release build of the tool leaves it out. `swift run Validate` builds for debugging.
#if DEBUG
    import Foundation
    import SQLite3
    @testable import TopoText

    /// Counts the stored values behind the decoded contents, and prints the counts in two sections.
    ///
    /// The first section has the protocol buffer fields, the style values that TopoText doesn't recognize,
    /// how titles relate to the text, and what the edit engine assumes about each stored document.
    /// The second section has the results of the edits that the tool applies in memory.
    /// Each section is printed as soon as it is complete, and standard error gets a line for every 200 notes,
    /// so a run that takes long shows where it is.
    ///
    /// Like the rest of the tool, it prints only counts and numbers that the format defines,
    /// never text, titles, identifiers, or file names.
    func inspectStoredContents(root: URL) throws {
        let database = try Database(root: root, timeLimit: .seconds(600))
        defer { database.close() }
        try database.readTransaction {
            var counts: [String: Int] = [:]
            func add(_ label: String, _ amount: Int = 1) {
                counts[label, default: 0] += amount
            }
            var sizes = SizeCounts()
            var examined = 0
            try forEachNote(in: database) { note, data in
                examined += 1
                if examined.isMultiple(of: 200) { progress("stored contents: \(examined) notes examined") }
                guard let data, let message = try? ProtobufMessage(data.gunzipped()).message(2)?.message(3) else {
                    add("stored: notes without contents that decode")
                    return
                }
                inspectRuns(of: message, add: add)
                inspectStoredDocument(data, sizes: &sizes, add: add)
                let content = try database.content(of: note)
                let category = titleCategory(title: note.title, content: content)
                add("titles: \(category)")
                if category.hasPrefix("not found") {
                    inspectUnmatchedTitle(note: note, content: content, add: add)
                }
                try inspectRows(of: note, category: category, database: database, add: add)
                try inspectScans(in: content, database: database, add: add)
            }
            try inspectLinkRows(database: database, add: add)
            printSection("Stored contents (internal decoders):", counts, sizes.lines)

            var trials = TrialCounts()
            examined = 0
            try forEachNote(in: database) { _, data in
                examined += 1
                if examined.isMultiple(of: 200) { progress("trial edits: \(examined) notes examined") }
                guard let data, let stored = try? StoredNote(data: data) else { return }
                trials.run(on: stored)
            }
            printSection("Trial edits in memory (internal decoders):", trials.counts, trials.lines)
        }
    }

    /// Calls a closure with each note that is not locked, and the note's stored contents.
    private func forEachNote(in database: Database, _ body: (Note, Data?) throws -> Void) throws {
        var cursor: Note.FetchRequest.Cursor?
        repeat {
            let result = try database.search(.init(includesRecentlyDeleted: true, limit: Note.FetchRequest.maximumLimit, cursor: cursor))
            for note in result.notes where !note.isLocked {
                try body(note, try database.noteData(rowID: note.rowID))
            }
            cursor = result.nextCursor
        } while cursor != nil
    }

    /// Prints a section of counts, in the order of their labels, and then other lines.
    private func printSection(_ title: String, _ counts: [String: Int], _ lines: [String]) {
        print("")
        print(title)
        for (label, count) in counts.sorted(by: { $0.key < $1.key }) {
            print("\(label): \(count)")
        }
        for line in lines {
            print(line)
        }
        // Standard output can be a file or a pipe, which keeps lines back until its buffer is full.
        fflush(stdout)
    }

    /// Writes a line to standard error, which shows that the tool is at work without becoming part of its output.
    private func progress(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    /// The upper end of the range of sizes that a count belongs to: 0, 10, 100, and so on.
    private func sizeLimit(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        var limit = 10
        while limit < count { limit *= 10 }
        return limit
    }

    /// The range of sizes that a count belongs to: "1 to 10", "11 to 100", and so on.
    private func sizeBucket(_ count: Int) -> String {
        let limit = sizeLimit(count)
        return limit == 0 ? "0" : limit == 10 ? "1 to 10" : "\(limit / 10 + 1) to \(limit)"
    }

    /// The sizes of the stored documents: how many notes have each size, and the size of the largest.
    private struct SizeCounts {
        /// For each measure, the number of notes by the upper end of the range that their size is in.
        private var counts: [String: [Int: Int]] = [:]

        mutating func add(_ stored: StoredNote) {
            let tombstones = stored.substrings.filter(\.isTombstone)
            let sizes = [
                ("UTF-16 code units of text", stored.length),
                ("UTF-16 code units of deleted text", tombstones.reduce(0) { $0 + $1.length }),
                ("substrings", stored.substrings.count),
                ("substrings with a tombstone", tombstones.count),
                ("attribute runs", stored.runs.count),
            ]
            for (name, size) in sizes {
                counts[name, default: [:]][sizeLimit(size), default: 0] += 1
            }
        }

        /// The number of notes in each range, from the smallest sizes to the largest.
        /// The largest note appears as a range too, so that no line is the exact size of one note.
        var lines: [String] {
            counts.sorted { $0.key < $1.key }.flatMap { name, notes in
                notes.sorted { $0.key < $1.key }.map { "sizes: notes with \(sizeBucket($0.key)) \(name): \($0.value)" }
                    + ["sizes: the largest number of \(name) in a note is \(sizeBucket(notes.keys.max() ?? 0))"]
            }
        }
    }

    /// The results of a trial that runs on another thread, which the main thread reads when the trial ends or its time is up.
    private final class TrialProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [(name: String, outcome: NoteEditTrial.Outcome)] = []
        private var current: String?

        func start(_ name: String) {
            lock.withLock { current = name }
        }

        func finish(_ name: String, _ outcome: NoteEditTrial.Outcome) {
            lock.withLock {
                outcomes.append((name, outcome))
                current = nil
            }
        }

        /// The trials that ended, and the name of the trial that is running.
        var state: (outcomes: [(name: String, outcome: NoteEditTrial.Outcome)], current: String?) {
            lock.withLock { (outcomes: outcomes, current: current) }
        }
    }

    /// Applies the trial edits to each document in memory, and counts each check that a result fails.
    ///
    /// The trials of a note run on another thread and have a time limit.
    /// When the time is up, the note counts as "timed out", with its form, and the tool goes on to the next note.
    /// The thread can't be stopped, so after a few such notes the tool runs no more trials.
    private struct TrialCounts {
        /// The time that the trials of one note may take. The largest synthetic note takes under a second.
        static let timeLimit = 20.0
        /// The number of notes that may time out before the tool stops running trials.
        static let timeoutLimit = 3

        private(set) var counts: [String: Int] = [:]
        private var timeouts = 0
        private var total: Duration = .zero
        private var slowest: Duration = .zero

        private mutating func add(_ label: String) {
            counts[label, default: 0] += 1
        }

        mutating func run(on stored: StoredNote) {
            guard stored.brokenInvariants.isEmpty else {
                add("trial: not run, the note lacks an invariant")
                return
            }
            guard timeouts < Self.timeoutLimit else {
                add("trial: not run, after \(Self.timeoutLimit) notes timed out")
                return
            }
            let progress = TrialProgress()
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                for trial in NoteEditTrial.trials(for: stored) {
                    progress.start(trial.name)
                    progress.finish(trial.name, trial.run(on: stored))
                }
                done.signal()
            }
            thread.stackSize = 8 << 20
            let start = ContinuousClock.now
            thread.start()
            let timedOut = done.wait(timeout: .now() + Self.timeLimit) == .timedOut
            let elapsed = ContinuousClock.now - start
            total += elapsed
            slowest = max(slowest, elapsed)

            let state = progress.state
            for (name, outcome) in state.outcomes {
                count(outcome, of: "trial, \(name)", in: stored)
            }
            if timedOut {
                timeouts += 1
                add("trial: timed out")
                if let current = state.current { add("trial, \(current): timed out") }
                add("trial: timed out, in a note with \(form(of: stored)), \(sizeBucket(stored.length)) UTF-16 code units of text")
            }
        }

        private mutating func count(_ outcome: NoteEditTrial.Outcome, of label: String, in stored: StoredNote) {
            switch outcome {
            case .sound:
                add("\(label): sound")
            case .refused(let reason):
                add("\(label): refused, \(reason)")
            case .failed:
                add("\(label): failed")
            case .undecodable:
                add("\(label): the result does not decode")
            case .unsound(let failures):
                add("\(label): not sound")
                for failure in failures {
                    add("\(label): not sound, \(failure)")
                }
                add("\(label): not sound, in a note with \(form(of: stored))")
            }
        }

        /// The form of a note, without its contents: how many replicas and substrings, and how branched the substrings are.
        private func form(of stored: StoredNote) -> String {
            let end = stored.substrings.count - 1
            let branched = stored.substrings.filter { $0.children.count > 1 }.count
            let toEnd = stored.substrings.filter { $0.children.contains(end) }.count
            let replicas = stored.replicas.count
            return "\(replicas <= 3 ? "\(replicas)" : replicas <= 10 ? "4 to 10" : "over 10") replicas, "
                + "\(sizeBucket(stored.substrings.count)) substrings, "
                + "\(branched == 0 ? "no" : "some") substrings with more than one child, "
                + "\(toEnd <= 1 ? "\(toEnd)" : "more than 1") that point to the end marker"
        }

        /// The time that the trials took, which is not part of the counts.
        var lines: [String] {
            func seconds(_ duration: Duration) -> String {
                String(format: "%.1f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
            }
            return ["time for the trial edits: \(seconds(total)) seconds, of which the slowest note took \(seconds(slowest))"]
        }
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
    /// It counts each invariant that the document lacks, the forms of the merge state, and the size of the document.
    /// Each step takes time in proportion to the size of the document.
    /// Like the rest of the tool, it prints only counts and numbers that the format defines.
    private func inspectStoredDocument(_ data: Data, sizes: inout SizeCounts, add: (String, Int) -> Void) {
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
        sizes.add(stored)
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
            let message = substring.message
            for number in Set(message.fields.map(\.number)) { add("merge state: Substring field \(number)", 1) }
            if substring.isTombstone { add("merge state: substrings with a tombstone of \(substring.tombstoneValue)", 1) }
            if substring.children.count > 1 { add("merge state: substrings with more than one child", 1) }
            if message.values(5).contains(where: { if case .bytes = $0 { true } else { false } }) {
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
            guard run.length > 0 else { continue }
            // Every paragraph that the run reaches, from the one of its first character to the one of its last.
            for paragraph in paragraphIndex(at: offset, in: starts) ... paragraphIndex(at: offset + run.length - 1, in: starts) {
                paragraphsByItem[identifier, default: []].insert(paragraph)
            }
        }
        for paragraphs in paragraphsByItem.values {
            add("checklists: identifiers in \(paragraphs.count == 1 ? "1 paragraph" : "more than 1 paragraph")", 1)
        }

        inspectStyleFields(of: stored, systemByte: data.count > 9 ? data[data.startIndex + 9] : nil, add: add)
    }

    /// The index of the paragraph that holds a position, by a binary search of the paragraphs' first positions.
    private func paragraphIndex(at position: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= position { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    /// Counts the fields that the edit engine does not write on new text, to decide whether it should:
    /// run field 13, and paragraph style fields 3 and 9.
    ///
    /// The values that it prints are enumeration values and ranges of numbers, never an identifier.
    private func inspectStyleFields(of stored: StoredNote, systemByte: UInt8?, add: (String, Int) -> Void) {
        func bucket(_ count: Int) -> String {
            count <= 3 ? "\(count)" : count <= 10 ? "4 to 10" : count <= 100 ? "11 to 100" : "over 100"
        }
        func magnitude(_ value: UInt64) -> String {
            switch value {
            case 0: return "0"
            case ..<100: return "1 to 99"
            case ..<100_000: return "100 to 99,999"
            case ..<500_000_000: return "100,000 to 499,999,999"
            case ..<1_000_000_000: return "500,000,000 to 999,999,999, which seconds since 2001 are in from 2016 to 2032"
            case ..<(1 << 32): return "1,000,000,000 to 2 to the power 32"
            default: return "above 2 to the power 32"
            }
        }
        func share(_ part: Int, of whole: Int) -> String {
            whole == 0 ? "none" : part == whole ? "all" : part == 0 ? "none" : "some"
        }
        let highestStyleClock = UInt64(stored.replicas.map(\.styleClock).max() ?? 0)
        let starts = stored.paragraphRanges.map(\.content.lowerBound)
        var timestamps: Set<UInt64> = []
        var paragraphsByIdentifier: [[UInt8]: Set<Int>] = [:]
        var styles = 0
        var stylesWithIdentifier = 0
        var previous: UInt64?
        var offset = 0
        for run in stored.runs {
            defer { offset += max(0, run.length) }
            let numbers = Set(run.message.fields.map(\.number)).sorted().map(String.init).joined(separator: ",")
            if let timestamp = run.message.varint(13) {
                timestamps.insert(timestamp)
                add("run field 13: values of \(magnitude(timestamp))", 1)
                add("run field 13: values \(timestamp <= highestStyleClock ? "at most" : "above") the note's highest style clock", 1)
                if let previous {
                    add("run field 13: \(timestamp == previous ? "the same as" : timestamp > previous ? "above" : "below") the run before", 1)
                }
                previous = timestamp
            } else {
                add("runs without field 13: with fields \(numbers)", 1)
            }
            guard let style = run.paragraphStyle else {
                add("runs without a paragraph style: with fields \(numbers)", 1)
                continue
            }
            styles += 1
            let type = style.int32(1).map(String.init) ?? "absent"
            if style.fields.isEmpty { add("paragraph styles: with no fields", 1) }
            add("paragraph style field 3: \(style.varint(3).map { "value \($0)" } ?? "absent"), with style type \(type)", 1)
            if let identifier = style.bytes(9) {
                stylesWithIdentifier += 1
                let version = identifier.count == 16 ? "\(identifier[6] >> 4)" : "none"
                add("paragraph style field 9: present with style type \(type), UUID version \(version)", 1)
                for position in [offset, offset + max(0, run.length - 1)] {
                    paragraphsByIdentifier[identifier, default: []].insert(paragraphIndex(at: position, in: starts))
                }
            } else {
                add("paragraph style field 9: absent with style type \(type)", 1)
            }
        }
        add("run field 13: notes with \(bucket(timestamps.count)) different values", 1)
        add("run field 13: notes with it on \(share(stored.runs.filter { $0.message.contains(13) }.count, of: stored.runs.count)) of the runs", 1)
        add("paragraph style field 9: notes with it on \(share(stylesWithIdentifier, of: styles)) of the styles", 1)
        for paragraphs in paragraphsByIdentifier.values {
            add("paragraph style field 9: values in \(paragraphs.count == 1 ? "1 paragraph" : "more than 1 paragraph")", 1)
        }
        if let systemByte {
            let field13 = share(stored.runs.filter { $0.message.contains(13) }.count, of: stored.runs.count)
            add("gzip: operating system byte \(systemByte), notes with \(bucket(stored.replicas.count)) replicas and field 13 on \(field13) of the runs", 1)
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
