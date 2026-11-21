import Foundation

/// An edit that the validation tool applies to a stored document in memory, to check the edit engine against real documents.
///
/// Nothing here writes the result anywhere.
/// The type is in the library, and not in the tool, so that the tests can run the same edits and the same checks,
/// and can bound the time that they take on a large document.
/// Each step takes time in proportion to the number of substrings, runs, and UTF-16 code units,
/// or that number times its logarithm: a note can hold tens of thousands of substrings, most of them deleted text.
struct NoteEditTrial: Sendable {
    /// What an edit is expected to change, in positions of the text before the edit.
    struct Expectation: Hashable, Sendable {
        /// The range of the text that the edit deletes.
        var replaced: Range<Int>
        /// The number of UTF-16 code units that the edit inserts at the start of the range.
        var inserted: Int
        /// The range whose attributes and style timestamps the edit may change, for a style operation.
        var restyled: Range<Int>?
        /// The UUID of the replica that makes the edit, or `nil` for a replica that is new to the document.
        var replica: [UInt8]?
    }

    /// The result of a trial. No case holds any of the note's contents.
    enum Outcome: Hashable, Sendable {
        /// The edit kept everything outside its range, and the result decodes to the same document.
        case sound
        /// The engine refused the edit, with the name of the error and, for an unsupported document, the invariant.
        case refused(String)
        /// The engine threw an error of another type.
        case failed
        /// The result does not decode as a stored document.
        case undecodable
        /// The checks that the result fails.
        case unsound([String])
    }

    /// A description of the edit, without any of the note's contents.
    var name: String
    var edit: NoteEdit
    var expectation: Expectation

    /// The trials for a document: a checklist item at the end, a character at the end of the first paragraph,
    /// the deletion of the first character of the last paragraph, and a change of the first checklist item's state.
    ///
    /// A document without the paragraph that a trial needs does not get that trial.
    static func trials(for stored: StoredNote) -> [NoteEditTrial] {
        let length = stored.length
        let paragraphs = stored.paragraphRanges
        var trials = [
            NoteEditTrial(
                name: "append a checklist item",
                edit: .appendParagraphs([.init("x", style: .checklist)]),
                expectation: .init(replaced: length ..< length, inserted: length == 0 || stored.text.utf16.last == 0x0A ? 1 : 2)
            )
        ]
        if let first = paragraphs.first {
            let end = first.content.upperBound
            trials.append(
                NoteEditTrial(
                    name: "insert text in the first paragraph",
                    edit: .insertText("x", at: .offset(end)),
                    expectation: .init(replaced: end ..< end, inserted: 1)
                )
            )
        }
        if let last = paragraphs.last, !last.content.isEmpty {
            let range = last.content.lowerBound ..< last.content.lowerBound + 1
            trials.append(
                NoteEditTrial(
                    name: "delete a character of the last paragraph",
                    edit: .deleteText(.range(range)),
                    expectation: .init(replaced: range, inserted: 0)
                )
            )
        }

        // The first paragraph whose first character is in a run with the checklist style.
        // The paragraphs and the runs are both in the order of the text, so one pass over each finds it.
        var runIndex = 0
        var runEnd = stored.runs.first.map { max(0, $0.length) } ?? 0
        for (index, paragraph) in paragraphs.enumerated() {
            let start = paragraph.full.lowerBound
            while runIndex < stored.runs.count, runEnd <= start {
                runIndex += 1
                if runIndex < stored.runs.count { runEnd += max(0, stored.runs[runIndex].length) }
            }
            guard runIndex < stored.runs.count else { break }
            guard stored.runs[runIndex].styleType == 103 else { continue }
            let isChecked = (stored.runs[runIndex].todo?.varint(2) ?? 0) == 1
            trials.append(
                NoteEditTrial(
                    name: "change a checklist item's state",
                    edit: .setChecked(!isChecked, at: .index(index)),
                    expectation: .init(replaced: start ..< start, inserted: 0, restyled: paragraph.full)
                )
            )
            break
        }
        return trials
    }

    /// Applies the edit to a document in memory, encodes and decodes the result, and checks it.
    func run(on stored: StoredNote) -> Outcome {
        let edited: StoredNote
        do {
            edited = try NoteEditor().apply([edit], to: stored)
        } catch let error as NoteEditError {
            // The name of the error's case, without the values that some cases carry.
            var reason = String(String(describing: error).prefix { $0 != "(" })
            if case .unsupportedDocument(let invariant) = error { reason += ", not true that \(invariant.rawValue)" }
            return .refused(reason)
        } catch {
            return .failed
        }
        let protobuf = edited.protobuf()
        guard let reread = try? StoredNote(protobuf: protobuf) else {
            return .undecodable
        }
        var failures = stored.failures(of: reread, expecting: expectation)
        // The text as ``NoteDocument`` reads it, from the same field with the read path's decoder.
        let readerText = (try? ProtobufMessage(Data(protobuf)))?.message(2)?.message(3).map { $0.string(2) ?? "" }
        if readerText != reread.text { failures.append("the reader's text differs") }
        if reread.protobuf() != protobuf { failures.append("the result decodes to another document") }
        return failures.isEmpty ? .sound : .unsound(failures)
    }
}

extension StoredNote {
    /// Returns what an edit of one range broke, as descriptions without any of the note's contents.
    ///
    /// An edit must keep the text and the attributes outside its range,
    /// and every character that the document recorded, in order, with its deletion state and style timestamp.
    /// The comparison works on whole substrings and runs, not on single characters,
    /// so its time does not grow with the amount of deleted text.
    /// - Parameters:
    ///   - edited: The document after the edit.
    ///   - expectation: What the edit is expected to change.
    func failures(of edited: StoredNote, expecting expectation: NoteEditTrial.Expectation) -> [String] {
        var failures = edited.brokenInvariants.map { "afterwards it is not true that \($0.rawValue)" }
        func require(_ condition: Bool, _ failure: String) {
            if !condition, !failures.contains(failure) { failures.append(failure) }
        }
        let replaced = expectation.replaced
        let inserted = expectation.inserted

        let old = Array(text.utf16)
        let new = Array(edited.text.utf16)
        let tail = old.count - replaced.upperBound
        require(new.count == old.count - replaced.count + inserted, "the text has another length than expected")
        require(new.prefix(replaced.lowerBound) == old.prefix(replaced.lowerBound), "the text before the edit changed")
        require(new.suffix(tail) == old.suffix(tail), "the text after the edit changed")

        let kept = expectation.restyled ?? replaced
        let keptTail = old.count - kept.upperBound
        let oldAttributes = attributes
        let newAttributes = edited.attributes
        require(
            Self.spans(newAttributes, in: 0 ..< kept.lowerBound) == Self.spans(oldAttributes, in: 0 ..< kept.lowerBound),
            "the attributes before the edit changed"
        )
        require(
            Self.spans(newAttributes, in: max(0, new.count - keptTail) ..< new.count) == Self.spans(oldAttributes, in: kept.upperBound ..< old.count),
            "the attributes after the edit changed"
        )
        // The replica that edits is the one that the expectation names, or else the one that the edit added.
        let editorUUID = expectation.replica ?? (edited.replicas.count > replicas.count ? edited.replicas[edited.replicas.count - 1].uuid : [])
        let isKnown = replicas.contains { $0.uuid == editorUUID }
        require(
            edited.replicas.count >= replicas.count && zip(replicas, edited.replicas).allSatisfy { $0 == $1 || $0.uuid == editorUUID },
            "the entry of another replica changed"
        )
        require(edited.replicas.count == replicas.count + (isKnown ? 0 : 1), "the edit did not add its replica, and that one alone")

        // A number for each replica of either document, so that the pieces compare without their UUIDs.
        var replicaNumbers: [[UInt8]: Int] = [:]
        for replica in replicas + edited.replicas where replicaNumbers[replica.uuid] == nil {
            replicaNumbers[replica.uuid] = replicaNumbers.count + 1
        }
        let before = segments(replicaNumbers)
        let after = edited.segments(replicaNumbers)

        // Walk both lists together. A piece of the edited document either continues the stored document,
        // with the same identifier, or it is new.
        let editor = replicaNumbers[editorUUID] ?? -1
        let boundaries = [replaced.lowerBound, replaced.upperBound] + (expectation.restyled.map { [$0.lowerBound, $0.upperBound] } ?? [])
        var oldIndex = 0
        var oldUsed = 0
        var newIndex = 0
        var newUsed = 0
        /// The position in the text before the edit, and in the text after it.
        var position = 0
        var newPosition = 0
        var added = 0
        var deletionsAsExpected = true
        var timestampsKept = true
        var addedAsExpected = true
        var addedInPlace = true
        while newIndex < after.count {
            let now = after[newIndex]
            if oldIndex < before.count {
                let was = before[oldIndex]
                if was.replica == now.replica, was.clock + oldUsed == now.clock + newUsed {
                    var count = min(was.length - oldUsed, now.length - newUsed)
                    if !was.isDeleted, let boundary = boundaries.filter({ $0 > position }).min() {
                        // Stop at the next end of a range, so that the whole piece is inside a range or outside it.
                        count = min(count, boundary - position)
                    }
                    let isInRange = !was.isDeleted && replaced.contains(position)
                    let mayBeRestyled = !was.isDeleted && (expectation.restyled?.contains(position) ?? false)
                    if now.isDeleted != (was.isDeleted || isInRange) { deletionsAsExpected = false }
                    if !isInRange, !mayBeRestyled, now.styleReplica != was.styleReplica || now.styleClock != was.styleClock {
                        timestampsKept = false
                    }
                    if !was.isDeleted { position += count }
                    if !now.isDeleted { newPosition += count }
                    oldUsed += count
                    newUsed += count
                    if oldUsed == was.length {
                        oldIndex += 1
                        oldUsed = 0
                    }
                    if newUsed == now.length {
                        newIndex += 1
                        newUsed = 0
                    }
                    continue
                }
            }
            // A piece that does not continue the stored document must be new text of the editor's replica, at the place of the edit.
            let count = now.length - newUsed
            if now.replica != editor || now.isDeleted { addedAsExpected = false }
            if newPosition != replaced.lowerBound + added { addedInPlace = false }
            added += count
            if !now.isDeleted { newPosition += count }
            newIndex += 1
            newUsed = 0
        }
        let allSurvive = oldIndex == before.count
        require(allSurvive, "a character is lost or out of order")
        if allSurvive {
            require(deletionsAsExpected, "a character outside the range is deleted, or one inside it is not")
            require(timestampsKept, "a style timestamp outside the edit changed")
        }
        require(added == inserted, "the number of new characters is not the number inserted")
        require(addedAsExpected, "a new character is deleted, or is not the editing replica's")
        require(addedInPlace, "the new characters are not where the edit was")
        return failures
    }

    /// The characters of one substring, with numbers for the replicas that two versions of a document share.
    private struct Segment {
        var replica: Int
        var clock: Int
        var length: Int
        var isDeleted: Bool
        var styleReplica: Int
        var styleClock: Int
    }

    /// The substrings that hold characters, deleted or not.
    /// - Parameter replicaNumbers: A number above 0 for each replica's UUID. The origin and the end marker have the number 0.
    private func segments(_ replicaNumbers: [[UInt8]: Int]) -> [Segment] {
        let numbers = replicas.map { replicaNumbers[$0.uuid] ?? 0 }
        func number(_ replica: Int) -> Int { replica >= 1 && replica <= numbers.count ? numbers[replica - 1] : 0 }
        var segments: [Segment] = []
        segments.reserveCapacity(substrings.count)
        for substring in substrings where !substring.isEnd && substring.length > 0 {
            segments.append(
                Segment(
                    replica: number(substring.id.replica),
                    clock: substring.id.clock,
                    length: substring.length,
                    isDeleted: substring.isTombstone,
                    styleReplica: number(substring.styleTimestamp.replica),
                    styleClock: substring.styleTimestamp.clock
                )
            )
        }
        return segments
    }

    private struct AttributeSpan: Equatable {
        /// A run's fields without its length.
        var fields: WireMessage
        var length: Int
    }

    /// The attributes of each run with a length above 0.
    private var attributes: [AttributeSpan] {
        runs.compactMap { run in
            guard run.length > 0 else { return nil }
            var fields = run.message
            fields.set(1, nil)
            return AttributeSpan(fields: fields, length: run.length)
        }
    }

    /// The attributes of a range of the text, with neighbors that have the same fields joined,
    /// so that a run that an edit split compares equal to the run that it was.
    private static func spans(_ attributes: [AttributeSpan], in range: Range<Int>) -> [AttributeSpan] {
        var spans: [AttributeSpan] = []
        var start = 0
        for span in attributes {
            let end = start + span.length
            defer { start = end }
            guard end > range.lowerBound else { continue }
            guard start < range.upperBound else { break }
            let count = min(end, range.upperBound) - max(start, range.lowerBound)
            if let last = spans.indices.last, spans[last].fields == span.fields {
                spans[last].length += count
            } else {
                spans.append(AttributeSpan(fields: span.fields, length: count))
            }
        }
        return spans
    }
}
