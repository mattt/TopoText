@testable import TopoText
import Foundation
import Testing

/// The replica that the tests edit with, unless they name another.
private let editor = replicaUUID(0x33)

/// Decodes a document, applies edits, encodes the result with gzip, and decodes that.
private func edit(_ protobuf: [UInt8], _ edits: [NoteEdit], replica: UInt8 = 0x33) throws -> (before: StoredNote, after: StoredNote) {
    let before = try StoredNote(protobuf: protobuf)
    let edited = try NoteEditor(replica: uuid(replica)).apply(edits, to: before)
    return (before, try StoredNote(data: try edited.data()))
}

/// Decodes the paragraphs of a stored document as ``Store`` reads them, without attachment rows.
private func decodedParagraphs(_ stored: StoredNote) throws -> [Note.Paragraph] {
    var resolver = AttachmentResolver { _ in [:] }
    return try resolver.content(of: NoteDocument(data: try stored.data())).paragraphs
}

/// Checks everything that an edit of one range must leave true:
/// the text and the attributes outside the range are the same,
/// every character that the document recorded is still recorded, in the same order,
/// only the characters of the range are newly deleted,
/// and the new characters belong to the editing replica and stand where the range was.
private func expectConsistent(
    _ before: StoredNote,
    _ after: StoredNote,
    replaced range: Range<Int>,
    inserted: Int,
    replica: [UInt8] = editor,
    attributesChangedIn styled: Range<Int>? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(after.brokenInvariants.isEmpty, sourceLocation: sourceLocation)
    #expect(after.isConnected, sourceLocation: sourceLocation)

    let old = Array(before.text.utf16)
    let new = Array(after.text.utf16)
    let tail = old.count - range.upperBound
    #expect(new.count == old.count - range.count + inserted, sourceLocation: sourceLocation)
    #expect(new.prefix(range.lowerBound) == old.prefix(range.lowerBound), sourceLocation: sourceLocation)
    #expect(new.suffix(tail) == old.suffix(tail), sourceLocation: sourceLocation)

    let oldAttributes = before.characterAttributes
    let newAttributes = after.characterAttributes
    let untouched = styled?.lowerBound ?? range.lowerBound
    let untouchedTail = styled.map { old.count - $0.upperBound } ?? tail
    #expect(newAttributes.prefix(untouched) == oldAttributes.prefix(untouched), sourceLocation: sourceLocation)
    #expect(newAttributes.suffix(untouchedTail) == oldAttributes.suffix(untouchedTail), sourceLocation: sourceLocation)

    struct Key: Hashable {
        var replica: [UInt8]
        var clock: Int
        init(_ character: StoredCharacter) {
            replica = character.replica
            clock = character.clock
        }
    }
    let oldCharacters = before.characters
    let newCharacters = after.characters
    let oldKeys = Set(oldCharacters.map(Key.init))
    #expect(Set(newCharacters.map(Key.init)).count == newCharacters.count, sourceLocation: sourceLocation)
    #expect(newCharacters.map(Key.init).filter(oldKeys.contains) == oldCharacters.map(Key.init), sourceLocation: sourceLocation)

    var expectedDeleted: [Key: Bool] = [:]
    var position = 0
    for character in oldCharacters {
        expectedDeleted[Key(character)] = character.isDeleted || range.contains(position)
        if !character.isDeleted { position += 1 }
    }
    #expect(
        newCharacters.allSatisfy { character in expectedDeleted[Key(character)].map { $0 == character.isDeleted } ?? true },
        sourceLocation: sourceLocation
    )

    let added = newCharacters.filter { !oldKeys.contains(Key($0)) }
    #expect(added.count == inserted, sourceLocation: sourceLocation)
    #expect(added.allSatisfy { $0.replica == replica && !$0.isDeleted }, sourceLocation: sourceLocation)
    let visible = newCharacters.filter { !$0.isDeleted }
    let positions = visible.indices.filter { !oldKeys.contains(Key(visible[$0])) }
    #expect(positions == Array(range.lowerBound ..< range.lowerBound + inserted), sourceLocation: sourceLocation)

    #expect(try NoteDocument(data: try after.data()).text == after.text, sourceLocation: sourceLocation)

    // The validation tool's check, which compares whole substrings and runs, finds nothing either.
    let failures = before.failures(of: after, expecting: .init(replaced: range, inserted: inserted, restyled: styled, replica: replica))
    #expect(failures == [], sourceLocation: sourceLocation)
}

@Suite struct NoteEditorParagraphTests {
    @Test("Paragraphs of each style are appended to the end of a note")
    func append() throws {
        let (before, after) = try edit(
            RichNote.protobuf,
            [
                .appendParagraphs([
                    .init("Done"), .init("Milk", style: .bulleted), .init("First", style: .numbered),
                    .init("Call", style: .checklist), .init("Paid", style: .checklist, isChecked: true),
                ])
            ]
        )
        #expect(after.text == RichNote.text + "\nDone\nMilk\nFirst\nCall\nPaid")
        try expectConsistent(before, after, replaced: 69 ..< 69, inserted: 26)

        let paragraphs = try decodedParagraphs(after)
        #expect(paragraphs.count == 11)
        #expect(paragraphs.suffix(5).map(\.style.kind) == [.body, .bulletedList, .numberedList, .checklist, .checklist])
        #expect(paragraphs.suffix(5).map(\.style.isChecked) == [false, false, false, false, true])
        #expect(paragraphs.suffix(5).map(\.text) == ["Done", "Milk", "First", "Call", "Paid"])
        // The paragraphs before them are as they were.
        #expect(Array(paragraphs.prefix(6)) == (try decodedParagraphs(before)))

        // The line feed that ends the old last paragraph joins that paragraph's run.
        #expect(after.runs[14].length == before.runs[14].length + 1)
        #expect(after.runs[14].hasSameAttributes(as: before.runs[14]))
        // Each new paragraph has a paragraph style with the writing direction of the nearest paragraph that has one.
        // Body text has no style type, as Notes stores it.
        #expect(after.runs[15].message.fields.map(\.number) == [1, 2])
        #expect(after.runs.suffix(5).map { $0.paragraphStyle?.fields.map(\.number) } == [[3], [1, 3], [1, 3], [1, 3, 5], [1, 3, 5]])
        #expect(after.runs.suffix(5).allSatisfy { $0.paragraphStyle?.varint(3) == 0 })

        // New checklist items get identifiers of their own, in 16 bytes.
        let identifiers = after.runs.compactMap { $0.todo?.bytes(1) }
        #expect(identifiers.count == 4)
        #expect(Set(identifiers).count == 4)
        #expect(identifiers.allSatisfy { $0.count == 16 })
        #expect(Array(identifiers.prefix(2)) == [RichNote.firstItem, RichNote.secondItem])
    }

    @Test("An appended paragraph updates the merge state as a new replica's insertion does")
    func appendMergeState() throws {
        let (before, after) = try edit(RichNote.protobuf, [.appendParagraphs([.init("Done"), .init("Call", style: .checklist)])])

        // The new replica starts at the highest clocks of the others, 59 and 10.
        #expect(after.replicas.count == 3)
        #expect(Array(after.replicas.prefix(2)) == before.replicas)
        #expect(after.replicas[2].uuid == editor)
        // It inserted 10 code units, and made one style operation, number 10.
        #expect(after.replicas[2].clocks == [69, 11])

        // The substrings before the insertion are as they were, but for the last one's child.
        #expect(Array(after.substrings.prefix(5)) == Array(before.substrings.prefix(5)))
        #expect(after.substrings.count == 9)
        // The line feed and the body paragraph were never styled; the checklist item was, by operation 10.
        #expect(after.substrings[6].id == .init(replica: 3, clock: 59))
        #expect(after.substrings[6].length == 6)
        #expect(after.substrings[6].styleTimestamp == .init(replica: 3, clock: 0))
        #expect(after.substrings[7].id == .init(replica: 3, clock: 65))
        #expect(after.substrings[7].length == 4)
        #expect(after.substrings[7].styleTimestamp == .init(replica: 3, clock: 10))
        #expect(after.substrings.map(\.children) == [[1], [2], [3], [4, 5], [5], [6], [7], [8], []])
        #expect(after.substrings[8].isEnd)
    }

    @Test("A replica's next insertion after its own makes its substring longer")
    func appendAgain() throws {
        let document = storedDocument([run("A\n")])
        // The replica that wrote the document appends to it.
        let (before, after) = try edit(document, [.appendParagraphs([.init("B")])], replica: 0x11)
        #expect(after.text == "A\nB")
        #expect(after.substrings.count == 3)
        #expect(after.substrings[1].length == 3)
        #expect(after.replicas.map(\.clocks) == [[3, 1]])
        #expect(after.runs.map(\.length) == [3])
        try expectConsistent(before, after, replaced: 2 ..< 2, inserted: 1, replica: replicaUUID(0x11))

        // Another replica adds a substring, and its style clock is 1 or more.
        let other = try edit(document, [.appendParagraphs([.init("B")])]).after
        #expect(other.substrings.count == 4)
        #expect(other.substrings[2].id == .init(replica: 2, clock: 2))
        #expect(other.replicas.map(\.clocks) == [[2, 1], [3, 1]])
    }

    @Test("A paragraph is appended to an empty note")
    func appendToEmpty() throws {
        let (before, after) = try edit(storedDocument([]), [.appendParagraphs([.init("First", style: .checklist)])])
        #expect(after.text == "First")
        try expectConsistent(before, after, replaced: 0 ..< 0, inserted: 5)
        #expect(after.substrings.map(\.children) == [[1], [2], []])
        #expect(after.substrings[1].styleTimestamp == .init(replica: 1, clock: 1))
        #expect(after.replicas.map(\.clocks) == [[5, 2]])
        #expect(try decodedParagraphs(after).map(\.style.kind) == [.checklist])
    }

    @Test("Each line of a new paragraph is a paragraph, and an empty line is an empty paragraph")
    func lines() throws {
        let document = storedDocument([run("A")])
        let after = try edit(document, [.appendParagraphs([.init("One\r\nTwo\nThree", style: .bulleted), .init(""), .init("End")])]).after
        #expect(after.text == "A\nOne\nTwo\nThree\n\nEnd")
        #expect(try decodedParagraphs(after).map(\.style.kind) == [.body, .bulletedList, .bulletedList, .bulletedList, .body, .body])

        #expect(throws: NoteEditError.emptyParagraph) { try edit(document, [.appendParagraphs([.init("", style: .checklist)])]) }
        #expect(throws: NoteEditError.attachmentCharacterInText) { try edit(document, [.appendParagraphs([.init("a\u{FFFC}")])]) }
        // No paragraphs change nothing.
        #expect(try edit(document, [.appendParagraphs([])]).after.protobuf() == document)
    }

    @Test("Paragraphs are inserted before and after a paragraph")
    func insertBeforeAndAfter() throws {
        var (before, after) = try edit(RichNote.protobuf, [.insertParagraphs([.init("Buy map", style: .checklist)], at: .before(.index(1)))])
        try expectConsistent(before, after, replaced: 10 ..< 10, inserted: 8)
        var paragraphs = try decodedParagraphs(after)
        #expect(paragraphs.map(\.text).prefix(4) == ["Trip plan", "Buy map", "Pack bags", "Book hotel"])
        #expect(paragraphs.map(\.style.kind).prefix(4) == [.title, .checklist, .checklist, .checklist])
        #expect(paragraphs.map(\.style.isChecked).prefix(4) == [false, false, true, false])
        #expect(after.runs[2] == before.runs[1])

        (before, after) = try edit(RichNote.protobuf, [.insertParagraphs([.init("Then rest")], at: .after(.containing("Book hotel")))])
        try expectConsistent(before, after, replaced: 31 ..< 31, inserted: 10)
        paragraphs = try decodedParagraphs(after)
        #expect(paragraphs[3].text == "Then rest" && paragraphs[3].style.kind == .body)

        // After the last paragraph is the end of the note.
        let atEnd = try edit(RichNote.protobuf, [.insertParagraphs([.init("Last")], at: .after(.index(5)))]).after
        #expect(atEnd.text == (try edit(RichNote.protobuf, [.appendParagraphs([.init("Last")])]).after.text))
    }

    @Test("A new paragraph takes the writing direction of the paragraph before it, or of the one after it")
    func writingDirection() throws {
        let document = storedDocument([
            run("One\n") { $0.message(2, paragraphStyle(0) { $0.int(3, 2) }) },
            run("Two\n"),
            run("Three\n") { $0.message(2, paragraphStyle(100) { $0.int(3, 1) }) },
        ])
        func directions(_ position: NoteEdit.ParagraphPosition) throws -> [UInt64?] {
            try edit(document, [.insertParagraphs([.init("New")], at: position)]).after.runs.map { $0.paragraphStyle?.varint(3) }
        }
        #expect(try directions(.before(.index(0))) == [2, 2, nil, 1])
        #expect(try directions(.before(.index(1))) == [2, 2, nil, 1])
        #expect(try directions(.after(.index(1))) == [2, nil, 2, 1])
        #expect(try directions(.end) == [2, nil, 1, 1])

        // A note without a writing direction gives none, and body text then has no paragraph style.
        let plain = try edit(storedDocument([run("One")]), [.appendParagraphs([.init("Two"), .init("Three", style: .bulleted)])]).after
        #expect(plain.runs.map { $0.paragraphStyle?.fields.map(\.number) } == [nil, nil, [1]])
        #expect(plain.runs.map(\.length) == [4, 4, 5])
    }

    @Test("A paragraph that is inserted in the middle of a run splits the run")
    func insertInsideRun() throws {
        let (before, after) = try edit(
            storedDocument([run("One\nTwo\n") { $0.int(5, 1) }]),
            [.insertParagraphs([.init("Mid", style: .bulleted)], at: .before(.index(1)))]
        )
        #expect(after.text == "One\nMid\nTwo\n")
        #expect(after.runs.map(\.length) == [4, 4, 4])
        #expect(after.runs[0].hasSameAttributes(as: before.runs[0]) && after.runs[2].hasSameAttributes(as: before.runs[0]))
        #expect(after.runs[1].styleType == 100)
        try expectConsistent(before, after, replaced: 4 ..< 4, inserted: 4)
    }

    @Test("Whole paragraphs are deleted with their line feeds")
    func deleteParagraphs() throws {
        var (before, after) = try edit(RichNote.protobuf, [.deleteParagraphs(.index(1), through: .index(2))])
        try expectConsistent(before, after, replaced: 10 ..< 31, inserted: 0)
        #expect(try decodedParagraphs(after).map(\.text).prefix(2) == ["Trip plan", "See the guide and \u{FFFC} \u{FFFC} \u{FFFC}"])

        // The last paragraph has no line feed, so it goes with the one before it.
        (before, after) = try edit(RichNote.protobuf, [.deleteParagraphs(.index(5), through: nil)])
        try expectConsistent(before, after, replaced: 56 ..< 69, inserted: 0)
        #expect(after.text.hasSuffix("\u{FFFC}\n\u{FFFC}"))
        #expect(try decodedParagraphs(after).count == 5)

        // The order of the two anchors doesn't matter.
        #expect(
            try edit(RichNote.protobuf, [.deleteParagraphs(.index(2), through: .index(1))]).after.text
                == (try edit(RichNote.protobuf, [.deleteParagraphs(.index(1), through: .index(2))]).after.text)
        )
    }
}

@Suite struct NoteEditorTextTests {
    @Test("Text inside a run takes all of the run's attributes")
    func insertInsideRun() throws {
        let (before, after) = try edit(RichNote.protobuf, [.insertText("d", at: .after(.init("gui")))])
        #expect(after.text.contains("See the guidde and"))
        try expectConsistent(before, after, replaced: 42 ..< 42, inserted: 1)
        #expect(after.runs.count == before.runs.count)
        #expect(after.runs[4].length == 6)
        #expect(after.runs[4].message.string(9) == RichNote.link)
    }

    @Test("Text next to a link takes the other attributes of the character before it, without the link")
    func insertAfterLink() throws {
        let (before, after) = try edit(RichNote.protobuf, [.insertText(" book", at: .after(.init("guide")))])
        #expect(after.text.contains("See the guide book and"))
        try expectConsistent(before, after, replaced: 44 ..< 44, inserted: 5)
        #expect(after.runs.count == before.runs.count + 1)
        #expect(after.runs[4] == before.runs[4])
        #expect(after.runs[5].message.fields.map(\.number) == [1, 6])
    }

    @Test("Text at the start of a paragraph takes that paragraph's style")
    func insertAtParagraphStart() throws {
        let (before, after) = try edit(RichNote.protobuf, [.insertText("Re", at: .startOfParagraph(.index(1)))])
        try expectConsistent(before, after, replaced: 10 ..< 10, inserted: 2)
        #expect(after.runs.map(\.length) == before.runs.map(\.length).enumerated().map { $0.offset == 1 ? $0.element + 2 : $0.element })
        let paragraph = try decodedParagraphs(after)[1]
        #expect(paragraph.text == "RePack bags" && paragraph.style.kind == .checklist && paragraph.style.isChecked)
        #expect(after.runs[1].todo?.bytes(1) == RichNote.firstItem)
    }

    @Test("Text at the end of a paragraph and before a match is inserted there")
    func insertAtEnds() throws {
        var (before, after) = try edit(RichNote.protobuf, [.insertText(" ok", at: .endOfParagraph(.index(5)))])
        try expectConsistent(before, after, replaced: 69 ..< 69, inserted: 3)
        #expect(after.text.hasSuffix("Notes 😀 end ok"))
        #expect(after.runs.last?.length == 15)

        (before, after) = try edit(RichNote.protobuf, [.insertText("big ", at: .before(.init("bags")))])
        try expectConsistent(before, after, replaced: 15 ..< 15, inserted: 4)
        #expect(try decodedParagraphs(after)[1].text == "Pack big bags")

        (before, after) = try edit(RichNote.protobuf, [.insertText("!", at: .endOfParagraph(.containing("hotel")))])
        try expectConsistent(before, after, replaced: 30 ..< 30, inserted: 1)
        #expect(try decodedParagraphs(after)[2].text == "Book hotel!")
    }

    @Test("Text in an empty last paragraph is body text")
    func insertInEmptyLastParagraph() throws {
        var after = try edit(storedDocument([run("A\n")]), [.insertText("B", at: .offset(2))]).after
        #expect(after.text == "A\nB" && after.runs.map(\.length) == [3])
        after = try edit(storedDocument([run("A\n") { $0.message(2, paragraphStyle(0)) }]), [.insertText("B", at: .offset(2))]).after
        #expect(after.runs.map(\.length) == [2, 1])
        #expect(try decodedParagraphs(after).map(\.style.kind) == [.title, .body])
    }

    @Test("Replacement text takes the attributes of the text that it replaces")
    func replace() throws {
        var (before, after) = try edit(RichNote.protobuf, [.replaceText(.match(.init("guide")), with: "map")])
        try expectConsistent(before, after, replaced: 39 ..< 44, inserted: 3)
        #expect(after.runs[4].length == 3 && after.runs[4].message.string(9) == RichNote.link)

        (before, after) = try edit(RichNote.protobuf, [.replaceText(.paragraphText(.index(2)), with: "Reserve a hostel")])
        try expectConsistent(before, after, replaced: 20 ..< 30, inserted: 16)
        let paragraph = try decodedParagraphs(after)[2]
        #expect(paragraph.text == "Reserve a hostel" && paragraph.style.kind == .checklist && !paragraph.style.isChecked)
        #expect(after.runs[2].todo?.bytes(1) == RichNote.secondItem)
        #expect(after.runs.count == before.runs.count)

        (before, after) = try edit(RichNote.protobuf, [.replaceText(.match(.init("😀")), with: "🙂🙂")])
        try expectConsistent(before, after, replaced: 63 ..< 65, inserted: 4)
    }

    @Test("A replacement deletes with a tombstone and the style timestamp of a deletion")
    func replaceMergeState() throws {
        let (before, after) = try edit(RichNote.protobuf, [.replaceText(.match(.init("hotel")), with: "hostel")])
        try expectConsistent(before, after, replaced: 25 ..< 30, inserted: 6)

        // The substring of 21 code units is split around the 5 that are deleted.
        // The new substring comes after the deleted one, and the last part keeps both children.
        #expect(after.substrings.map(\.length) == [0, 10, 4, 15, 5, 6, 1, 10, 28, 0])
        #expect(after.substrings.map(\.id.clock) == [0, 0, 0, 10, 25, 59, 30, 4, 31, 0xFFFF_FFFF])
        #expect(after.substrings.map(\.id.replica) == [0, 1, 2, 1, 1, 3, 1, 2, 1, 0])
        #expect(after.substrings.map(\.isTombstone) == [false, false, true, false, true, false, false, false, false, false])
        #expect(after.substrings.map(\.children) == [[1], [2], [3], [4], [5], [6], [7, 8], [8], [9], []])
        // The deleted text had the style clock 3. The floor is 10, so 3 + 8 wins.
        #expect(after.substrings[4].styleTimestamp == .init(replica: 3, clock: 11))
        #expect(after.substrings[3].styleTimestamp == before.substrings[3].styleTimestamp)
        #expect(after.substrings[6].styleTimestamp == before.substrings[3].styleTimestamp)
        #expect(after.substrings[5].styleTimestamp == .init(replica: 3, clock: 0))
        #expect(after.replicas[2].clocks == [65, 12])
        // The substring that was deleted before keeps its field that no schema names.
        #expect(after.substrings[2] == before.substrings[2])
    }

    @Test("Text is deleted within a paragraph, and from the start of one paragraph into another")
    func delete() throws {
        var (before, after) = try edit(RichNote.protobuf, [.deleteText(.match(.init(" end")))])
        try expectConsistent(before, after, replaced: 65 ..< 69, inserted: 0)

        (before, after) = try edit(RichNote.protobuf, [.deleteText(.range(0 ..< 15))])
        try expectConsistent(before, after, replaced: 0 ..< 15, inserted: 0)
        let first = try decodedParagraphs(after)[0]
        #expect(first.text == "bags" && first.style.kind == .checklist && first.style.isChecked)

        // To the end of the note from inside a paragraph.
        (before, after) = try edit(RichNote.protobuf, [.deleteText(.range(60 ..< 69))])
        try expectConsistent(before, after, replaced: 60 ..< 69, inserted: 0)
    }

    @Test("An edit that changes nothing returns the same document")
    func noChange() throws {
        let edits: [NoteEdit] = [
            .replaceText(.match(.init("guide")), with: "guide"), .insertText("", at: .offset(3)), .deleteText(.range(5 ..< 5)),
            .setChecked(true, at: .index(1)), .setChecked(false, at: .containing("Book")),
        ]
        #expect(try edit(RichNote.protobuf, edits).after.protobuf() == RichNote.protobuf)
        #expect(try edit(RichNote.protobuf, []).after.protobuf() == RichNote.protobuf)
    }

    @Test("An edit never deletes or splits an attachment")
    func attachments() throws {
        func error(_ edit: NoteEdit, in document: [UInt8] = RichNote.protobuf) -> NoteEditError? {
            do {
                _ = try TopoTextTests.edit(document, [edit])
                return nil
            } catch {
                return error as? NoteEditError
            }
        }
        #expect(error(.deleteText(.range(48 ..< 51))) == .attachmentInRange(type: inlineType("hashtag")))
        #expect(error(.replaceText(.range(51 ..< 52), with: "x")) == .attachmentInRange(type: inlineType("mention")))
        #expect(error(.deleteText(.match(.init("\u{FFFC}", occurrence: 3)))) == .attachmentInRange(type: inlineType("link")))
        #expect(error(.deleteParagraphs(.index(3), through: nil)) == .attachmentInRange(type: inlineType("hashtag")))
        #expect(error(.deleteText(.paragraphText(.index(3)))) == .attachmentInRange(type: inlineType("hashtag")))

        // A table is one character of the text, in a paragraph of its own.
        #expect(error(.deleteText(.range(54 ..< 57))) == .tableInRange)
        #expect(error(.deleteParagraphs(.index(4), through: nil)) == .tableInRange)
        #expect(error(.deleteParagraphs(.index(2), through: .index(5))) == .attachmentInRange(type: inlineType("hashtag")))
        #expect(error(.insertText("x", at: .startOfParagraph(.index(4)))) == .tableInParagraph)
        #expect(error(.insertText("x", at: .endOfParagraph(.index(4)))) == .tableInParagraph)
        // New paragraphs around the table are fine.
        #expect(error(.insertParagraphs([.init("Before")], at: .before(.index(4)))) == nil)
        #expect(error(.insertParagraphs([.init("After")], at: .after(.index(4)))) == nil)
        // So is text next to an inline attachment.
        #expect(error(.insertText("x", at: .offset(50))) == nil)

        // An attachment's run can hold more than its character. Nothing goes inside the run.
        let wide = storedDocument([run("A"), run("\u{FFFC}\n") { $0.message(12, attachmentInfo("FILE-1", "public.jpeg")) }, run("B")])
        #expect(error(.insertText("x", at: .offset(2)), in: wide) == .insideAttachment)
        #expect(error(.insertParagraphs([.init("x")], at: .before(.index(1))), in: wide) == nil)
        #expect(error(.insertParagraphs([.init("x")], at: .after(.index(0))), in: wide) == nil)
        let across = storedDocument([run("A\n"), run("\u{FFFC}\nB") { $0.message(12, attachmentInfo("FILE-1", "public.jpeg")) }])
        #expect(error(.insertParagraphs([.init("x")], at: .before(.index(2))), in: across) == .insideAttachment)

        // The text that an inserted attachment character would stand in is refused too.
        #expect(error(.insertText("\u{FFFC}", at: .offset(0))) == .attachmentCharacterInText)
    }

    @Test("An edit keeps attachment runs as they were")
    func attachmentRunsKept() throws {
        let (before, after) = try edit(
            RichNote.protobuf,
            [.insertText("x", at: .offset(50)), .insertText("y", at: .offset(49)), .deleteText(.match(.init(" and ")))]
        )
        #expect(after.runs.filter(\.hasAttachment) == before.runs.filter(\.hasAttachment))
        #expect(after.text.utf16.filter { $0 == 0xFFFC }.count == 4)
        #expect(after.brokenInvariants.isEmpty)
    }

    @Test("A range can't join parts of two paragraphs, hold a line feed in new text, or split a character")
    func refusedRanges() throws {
        #expect(throws: NoteEditError.joinsParagraphs) { try edit(RichNote.protobuf, [.deleteText(.range(5 ..< 15))]) }
        #expect(throws: NoteEditError.joinsParagraphs) { try edit(RichNote.protobuf, [.replaceText(.range(0 ..< 15), with: "X")]) }
        #expect(throws: NoteEditError.joinsParagraphs) { try edit(RichNote.protobuf, [.deleteText(.range(9 ..< 10))]) }
        #expect(throws: NoteEditError.lineFeedInText) { try edit(RichNote.protobuf, [.insertText("a\nb", at: .offset(0))]) }
        #expect(throws: NoteEditError.lineFeedInText) { try edit(RichNote.protobuf, [.replaceText(.match(.init("Trip")), with: "a\r")]) }
        #expect(throws: NoteEditError.splitsCharacter) { try edit(RichNote.protobuf, [.insertText("x", at: .offset(64))]) }
        #expect(throws: NoteEditError.splitsCharacter) { try edit(RichNote.protobuf, [.deleteText(.range(62 ..< 64))]) }
        #expect(throws: NoteEditError.outOfBounds) { try edit(RichNote.protobuf, [.insertText("x", at: .offset(70))]) }
        #expect(throws: NoteEditError.outOfBounds) { try edit(RichNote.protobuf, [.deleteText(.range(-1 ..< 2))]) }
    }
}

@Suite struct NoteEditorChecklistTests {
    @Test("Setting a checklist item's state changes that item alone")
    func setChecked() throws {
        let (before, after) = try edit(RichNote.protobuf, [.setChecked(true, at: .index(2))])
        try expectConsistent(before, after, replaced: 20 ..< 20, inserted: 0, attributesChangedIn: 20 ..< 31)
        #expect(after.text == before.text)
        #expect(after.runs.count == before.runs.count)
        #expect(after.runs[2].todo?.bytes(1) == RichNote.secondItem)
        #expect(after.runs[2].todo?.varint(2) == 1)
        // The other fields of the paragraph style, known or not, are as they were.
        #expect(after.runs[2].paragraphStyle?.bytes(9) == before.runs[2].paragraphStyle?.bytes(9))
        #expect(after.runs[1] == before.runs[1])
        #expect(try decodedParagraphs(after).map(\.style.isChecked) == [false, true, true, false, false, false])

        // The item's text gets the style timestamp of the replica's operation 10. The rest keeps its own.
        #expect(after.substrings.map(\.length) == [0, 10, 4, 10, 11, 10, 28, 0])
        #expect(after.substrings[3].styleTimestamp == .init(replica: 2, clock: 3))
        #expect(after.substrings[4].styleTimestamp == .init(replica: 3, clock: 10))
        #expect(after.substrings.map(\.children) == [[1], [2], [3], [4], [5, 6], [6], [7], []])
        #expect(after.replicas[2].clocks == [59, 11])

        let unchecked = try edit(RichNote.protobuf, [.setChecked(false, at: .containing("Pack"))]).after
        #expect(try decodedParagraphs(unchecked).map(\.style.isChecked) == [false, false, false, false, false, false])
        #expect(unchecked.runs[1].todo?.bytes(1) == RichNote.firstItem)
        #expect(throws: NoteEditError.notChecklistItem) { try edit(RichNote.protobuf, [.setChecked(true, at: .index(0))]) }
    }

    @Test("Only the part of a run in the paragraph changes, and an item without a state gets one")
    func setCheckedOddRuns() throws {
        let item = Array(repeating: UInt8(0x5A), count: 16)
        var (before, after) = try edit(
            storedDocument([run("A\nB\n") { $0.message(2, paragraphStyle(103, todo: (item, 0))) }]),
            [.setChecked(true, at: .index(1))]
        )
        #expect(after.runs.map(\.length) == [2, 2])
        #expect(
            after.runs[0] == StoredNote.AttributeRun(try WireMessage(before.runs[0].message.encoded().enumerated().map { $0.offset == 1 ? 2 : $0.element }))
        )
        #expect(after.runs.map { $0.todo?.varint(2) } == [0, 1])
        #expect(after.runs.map { $0.todo?.bytes(1) } == [item, item])

        (before, after) = try edit(storedDocument([run("A") { $0.message(2, paragraphStyle(103)) }]), [.setChecked(true, at: .index(0))])
        #expect(before.runs[0].todo == nil)
        #expect(after.runs[0].todo?.bytes(1)?.count == 16)
        #expect(after.runs[0].todo?.varint(2) == 1)
        #expect(try edit(storedDocument([run("A") { $0.message(2, paragraphStyle(103)) }]), [.setChecked(false, at: .index(0))]).after == before)
    }
}

@Suite struct NoteEditorMergeStateTests {
    @Test("The floor of a pass is past every style timestamp that would win against the replica")
    func floor() throws {
        let substrings = [
            originSubstring,
            SubstringSpec(replica: 1, clock: 0, length: 2, style: (1, 5)),
            SubstringSpec(replica: 1, clock: 2, length: 3, style: (2, 5)),
            endSubstring,
        ]
        let replicas = [ReplicaSpec(uuid: replicaUUID(0x22), clocks: [5, 2]), ReplicaSpec(uuid: replicaUUID(0x44), clocks: [0, 3])]
        let document = try StoredNote(protobuf: storedDocument([run("Hello")], substrings: substrings, replicas: replicas))

        // The highest timestamp is (0x44, 5). A replica with a lower UUID loses a tie, so it starts at 6.
        var note = document
        #expect(note.beginPass(replica: replicaUUID(0x33)).floor == 6)
        #expect(note.replicas[2].clocks == [5, 3])
        // A replica with a higher UUID wins the tie at 5.
        note = document
        #expect(note.beginPass(replica: replicaUUID(0x55)).floor == 5)
        // The holder of the highest timestamp goes past its own.
        note = document
        #expect(note.beginPass(replica: replicaUUID(0x44)).floor == 6)
        #expect(note.replicas.count == 2)
        // The floor is never below the replica's own style clock.
        var ahead = try StoredNote(protobuf: storedDocument([run("Hello")], replicas: [ReplicaSpec(uuid: replicaUUID(0x11), clocks: [5, 40])]))
        #expect(ahead.beginPass(replica: replicaUUID(0x11)).floor == 40)
    }

    @Test("A style operation gives the old clock plus 1, and a deletion the old clock plus 8, or the floor")
    func stamps() throws {
        let substrings = [originSubstring, SubstringSpec(replica: 1, clock: 0, length: 6, style: (1, 20)), endSubstring]
        let replicas = [ReplicaSpec(uuid: replicaUUID(0x44), clocks: [6, 21])]
        let document = try StoredNote(
            protobuf: storedDocument([run("Hello\n") { $0.message(2, paragraphStyle(103)) }], substrings: substrings, replicas: replicas)
        )

        var note = try NoteEditor(replica: uuid(0x33)).apply([.setChecked(true, at: .index(0))], to: document)
        #expect(note.substrings[1].styleTimestamp == .init(replica: 2, clock: 21))
        #expect(note.replicas[1].clocks == [6, 22])

        note = try NoteEditor(replica: uuid(0x33)).apply([.deleteText(.match(.init("ell")))], to: document)
        #expect(note.substrings.map(\.styleTimestamp.clock) == [0, 20, 28, 20, 0xFFFF_FFFF])
        #expect(note.replicas[1].clocks == [6, 29])

        // A later edit by the same replica continues from its clocks.
        note = try NoteEditor(replica: uuid(0x33)).apply([.insertText("y", at: .offset(1))], to: note)
        #expect(note.replicas[1].clocks == [7, 29])
        // The new substring goes after the deleted one.
        #expect(note.substrings[3].id == .init(replica: 2, clock: 6))
        #expect(note.brokenInvariants.isEmpty)
    }

    @Test("An insertion where the neighbors have no edge takes over the children of the substring before it")
    func branchedInsertion() throws {
        // Two replicas inserted after the first substring: it has two children, and the second has no edge to the third.
        let substrings = [
            originSubstring,
            SubstringSpec(replica: 1, clock: 0, length: 1, style: (1, 0), children: [2, 3]),
            SubstringSpec(replica: 2, clock: 0, length: 1, style: (2, 0), children: [4]),
            SubstringSpec(replica: 1, clock: 1, length: 1, style: (1, 0), children: [4]),
            endSubstring,
        ]
        let replicas = [ReplicaSpec(uuid: replicaUUID(0x11), clocks: [2, 1]), ReplicaSpec(uuid: replicaUUID(0x22), clocks: [1, 1])]
        let (before, after) = try edit(storedDocument([run("abc")], substrings: substrings, replicas: replicas), [.insertText("X", at: .offset(2))])
        #expect(after.text == "abXc")
        #expect(after.substrings.map(\.children) == [[1], [2, 4], [3], [5], [5], []])
        try expectConsistent(before, after, replaced: 2 ..< 2, inserted: 1)
    }

    @Test("An insertion changes the child indexes of earlier substrings that point past it, and nothing else of them")
    func appendToBranchedDocument() throws {
        // Two substrings point to the end marker, as after concurrent insertions at the end of a note.
        let substrings = [
            originSubstring,
            SubstringSpec(replica: 1, clock: 0, length: 1, style: (1, 0), children: [2, 3]),
            SubstringSpec(replica: 2, clock: 0, length: 1, style: (2, 0), children: [4]),
            SubstringSpec(replica: 1, clock: 1, length: 1, style: (1, 0), children: [4]),
            endSubstring,
        ]
        let replicas = [ReplicaSpec(uuid: replicaUUID(0x11), clocks: [2, 1]), ReplicaSpec(uuid: replicaUUID(0x22), clocks: [1, 1])]
        let (before, after) = try edit(storedDocument([run("abc")], substrings: substrings, replicas: replicas), [.appendParagraphs([.init("d")])])
        try expectConsistent(before, after, replaced: 3 ..< 3, inserted: 2)
        // The end marker moved from index 4 to 5, so the earlier substring that points to it has another index for it.
        #expect(after.substrings.map(\.children) == [[1], [2, 3], [5], [4], [5], []])
        #expect(after.substrings[2] != before.substrings[2])
        var moved = before.substrings[2]
        moved.children = [5]
        #expect(after.substrings[2].message.encoded() == moved.message.encoded())
    }

    @Test("Fields that no schema names, and the parts that an edit does not touch, keep their bytes")
    func unknownFieldsKept() throws {
        let (before, after) = try edit(
            RichNote.protobuf,
            [.insertText("!", at: .endOfParagraph(.index(0))), .setChecked(true, at: .index(2)), .appendParagraphs([.init("New", style: .numbered)])]
        )
        let document = try WireMessage(after.protobuf())
        let version = try #require(document.message(2))
        let string = try #require(version.message(3))
        #expect(document.string(15) == "document" && document.varint(1) == 0)
        #expect(version.varint(7) == 42 && version.varint(1) == 0 && version.varint(2) == 0)
        #expect(string.message(6)?.string(2) == "ATTACHMENT-DATA")
        #expect(string.values(100) == [.fixed32(Float(1.5).bitPattern)])
        // Built up in steps: one long array concatenation here is slow enough
        // to type-check that Swift 6.1 and 6.2 give up on it.
        var expectedFields = [2]
        expectedFields += Array(repeating: 3, count: after.substrings.count)
        expectedFields.append(4)
        expectedFields += Array(repeating: 5, count: after.runs.count)
        expectedFields += [6, 100]
        #expect(string.fields.map(\.number) == expectedFields)

        #expect(after.substrings.first(where: \.isTombstone)?.message.string(9) == "substring")
        #expect(after.replicas[1].message.string(5) == "replica")
        #expect(Array(after.replicas.prefix(2)) == before.replicas)
        // The title's run keeps its font and field 13, and grew by one.
        #expect(after.runs[0].message.varint(13) == 5 && after.runs[0].message.message(3)?.string(1) == "Helvetica")
        #expect(after.runs[0].length == 11)
        // Runs outside the edits have the bytes that they had.
        for index in [1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13] {
            #expect(after.runs[index].message.encoded() == before.runs[index].message.encoded())
        }
    }

    @Test("Random edits keep the document consistent")
    func randomEdits() throws {
        var generator = SplitMix(state: 0x70_70_74)
        let insertions = ["a", "xyz", "é", "😀", " two words ", "1"]
        var note = try RichNote.stored()
        var applied = 0
        for step in 0 ..< 240 {
            let replica: UInt8 = step % 3 == 0 ? 0x33 : step % 3 == 1 ? 0x09 : 0xEE
            let length = note.length
            let lower = Int.random(in: 0 ... length, using: &generator)
            let upper = min(length, lower + Int.random(in: 0 ... 6, using: &generator))
            let text = Bool.random(using: &generator) ? insertions.randomElement(using: &generator)! : ""
            let edit: NoteEdit
            switch Int.random(in: 0 ..< 10, using: &generator) {
            case 0:
                edit = .appendParagraphs([.init("Item \(step)", style: [.body, .bulleted, .numbered, .checklist].randomElement(using: &generator)!)])
            case 1:
                edit = .insertParagraphs(
                    [.init("Line \(step)", style: .checklist)],
                    at: .before(.index(Int.random(in: 0 ..< note.paragraphRanges.count, using: &generator)))
                )
            default:
                edit = .replaceText(.range(lower ..< upper), with: text)
            }
            let before = note
            do {
                note = try NoteEditor(replica: uuid(replica)).apply([edit], to: note)
            } catch let error as NoteEditError {
                // The fixture has attachments, a table, and a character of two code units, so some edits are refused.
                let expected: [NoteEditError] = [.tableInRange, .tableInParagraph, .joinsParagraphs, .splitsCharacter, .insideAttachment]
                if case .attachmentInRange = error { continue }
                #expect(expected.contains(error), "step \(step): \(error)")
                continue
            }
            note = try StoredNote(data: try note.data())
            applied += 1
            switch edit {
            case .replaceText(.range(let range), let text):
                guard note != before else { continue }
                try expectConsistent(before, note, replaced: range, inserted: text.utf16.count, replica: replicaUUID(replica))
            default:
                #expect(note.brokenInvariants.isEmpty && note.isConnected, "step \(step)")
                #expect(note.characters.count > before.characters.count)
            }
            #expect(note.text.utf16.filter { $0 == 0xFFFC }.count == 4)
            #expect(note.runs.filter(\.hasAttachment) == before.runs.filter(\.hasAttachment))
        }
        #expect(applied > 100)
        #expect(Array(note.replicas.prefix(2)).map(\.uuid) == [RichNote.firstReplica, RichNote.secondReplica])
        #expect(note.replicas.count == 5)
    }
}

/// A random number generator with a seed, so that a failure can be repeated.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

@Suite struct NoteEditorAnchorTests {
    @Test("A match must be there, and be the only one unless the edit says which")
    func matches() throws {
        let note = try RichNote.stored()
        #expect(try note.range(of: NoteEdit.TextMatch("hotel")) == 25 ..< 30)
        #expect(try note.range(of: NoteEdit.TextMatch("a", in: .index(0))) == 7 ..< 8)
        #expect(try note.range(of: NoteEdit.TextMatch("a", in: .containing("Pack"), occurrence: 2)) == 16 ..< 17)
        #expect(try note.range(of: NoteEdit.TextMatch("😀")) == 63 ..< 65)
        #expect(throws: NoteEditError.ambiguousText("a", matches: 4)) { try note.range(of: NoteEdit.TextMatch("a")) }
        #expect(throws: NoteEditError.occurrenceNotFound("a", matches: 4)) { try note.range(of: NoteEdit.TextMatch("a", occurrence: 5)) }
        #expect(throws: NoteEditError.occurrenceNotFound("a", matches: 4)) { try note.range(of: NoteEdit.TextMatch("a", occurrence: 0)) }
        #expect(throws: NoteEditError.textNotFound("zebra")) { try note.range(of: NoteEdit.TextMatch("zebra")) }
        #expect(throws: NoteEditError.textNotFound("")) { try note.range(of: NoteEdit.TextMatch("")) }
        // A tag's text is not in the stored text, so a match can't span the tag.
        #expect(throws: NoteEditError.textNotFound("and #tag")) { try note.range(of: NoteEdit.TextMatch("and #tag")) }
        // A match stays inside its paragraph.
        #expect(throws: NoteEditError.textNotFound("hotel")) { try note.range(of: NoteEdit.TextMatch("hotel", in: .index(1))) }
    }

    @Test("A paragraph is named by its index or by text that only it contains")
    func paragraphs() throws {
        let note = try RichNote.stored()
        #expect(try note.paragraph(.index(5)) == 5)
        #expect(try note.paragraph(.containing("hotel")) == 2)
        #expect(throws: NoteEditError.paragraphNotFound(.index(6))) { try note.paragraph(.index(6)) }
        #expect(throws: NoteEditError.paragraphNotFound(.index(-1))) { try note.paragraph(.index(-1)) }
        #expect(throws: NoteEditError.paragraphNotFound(.containing("zebra"))) { try note.paragraph(.containing("zebra")) }
        #expect(throws: NoteEditError.ambiguousParagraph(.containing("k"), matches: 2)) { try note.paragraph(.containing("k")) }
    }

    @Test("A match finds a character however it is composed")
    func composedCharacters() throws {
        let (before, after) = try edit(storedDocument([run("Cafe\u{301} menu")]), [.replaceText(.match(.init("Caf\u{E9}")), with: "Tea")])
        #expect(after.text == "Tea menu")
        try expectConsistent(before, after, replaced: 0 ..< 5, inserted: 3)
    }

    @Test("Each edit sees the note as the edits before it left it, and a failure applies none of them")
    func batches() throws {
        let after = try edit(
            RichNote.protobuf,
            [.insertText("Big ", at: .startOfParagraph(.index(0))), .replaceText(.match(.init("Big Trip")), with: "Long trip")]
        ).after
        #expect(after.text.hasPrefix("Long trip plan\n"))
        #expect(throws: NoteEditError.textNotFound("zebra")) {
            try edit(RichNote.protobuf, [.insertText("Big ", at: .offset(0)), .deleteText(.match(.init("zebra")))])
        }
    }
}

@Suite struct NoteEditorRefusalTests {
    @Test("A locked note is refused before its contents are read")
    func lockedNote() async throws {
        let folder = try NotesFolder.current()
        let store = Store(root: folder.root)
        let secret = try await store.note(for: .id("NOTE-SECRET"))
        let edits = [NoteEdit.appendParagraphs([.init("More")])]
        #expect(throws: NoteEditError.noteLocked(.id("NOTE-SECRET"))) {
            try NoteEditor().edit(try Data(RichNote.protobuf).gzipped(), of: secret, applying: edits)
        }

        // An unlocked note is edited from its contents to new contents.
        let groceries = try await store.note(for: .id("NOTE-GROCERIES"))
        let data = try NoteEditor().edit(try Data(RichNote.protobuf).gzipped(), of: groceries, applying: edits)
        #expect(try NoteDocument(data: data).text == RichNote.text + "\nMore")
        #expect(throws: NoteEditError.unreadableContent) { try NoteEditor().edit(Data("bplist00".utf8), of: groceries, applying: edits) }
        #expect(throws: NoteEditError.unreadableContent) { try NoteEditor().edit(Data(), of: groceries, applying: edits) }
    }

    @Test("A document without the properties that an edit relies on is refused")
    func unsupportedDocuments() throws {
        let edits = [NoteEdit.appendParagraphs([.init("More")])]
        func error(_ protobuf: [UInt8]) -> NoteEditError? {
            do {
                _ = try edit(protobuf, edits)
                return nil
            } catch {
                return error as? NoteEditError
            }
        }
        // The documents that the reader's fixtures hold have no merge state.
        #expect(error(noteProtobuf([RunSpec(text: "Plain")])) == .unsupportedDocument(.vectorTimestamp))
        #expect(error(storedDocument([run("Two")], versions: 2)) == .unsupportedDocument(.oneVersion))
        #expect(
            error(storedDocument([run("Sub")], replicas: [ReplicaSpec(uuid: replicaUUID(0x11), clocks: [3, 1], subclock: 1)]))
                == .unsupportedDocument(.noSubclock)
        )
        #expect(error(storedDocument([run("Sub")], substrings: [originSubstring, endSubstring])) == .unsupportedDocument(.substringLengths))
        // With no edits, a document comes back as it is, whatever it lacks.
        let plain = noteProtobuf([RunSpec(text: "Plain")])
        #expect(try edit(plain, []).after.protobuf() == plain)
    }

    @Test("Each error says why the edit was not made")
    func descriptions() {
        let errors: [NoteEditError] = [
            .noteLocked(.id("N")), .unreadableContent, .unsupportedDocument(.runLengths), .paragraphNotFound(.index(3)),
            .paragraphNotFound(.containing("x")), .ambiguousParagraph(.containing("x"), matches: 2), .textNotFound("x"),
            .ambiguousText("x", matches: 2), .occurrenceNotFound("x", matches: 1), .outOfBounds, .splitsCharacter,
            .attachmentInRange(type: "public.jpeg"), .tableInRange, .insideAttachment, .tableInParagraph, .joinsParagraphs,
            .lineFeedInText, .attachmentCharacterInText, .emptyParagraph, .notChecklistItem,
        ]
        let descriptions = errors.map { $0.localizedDescription }
        #expect(Set(descriptions).count == errors.count)
        #expect(descriptions.allSatisfy { !$0.isEmpty && !$0.contains("NoteEditError") })
        #expect(NoteEditError.tableInRange.localizedDescription.contains("table"))
        #expect(NoteEditError.attachmentInRange(type: "public.jpeg").localizedDescription.contains("public.jpeg"))
    }
}
