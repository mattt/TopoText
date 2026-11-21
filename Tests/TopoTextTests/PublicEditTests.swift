import Foundation
import Testing
import TopoText

// This file imports TopoText as a package client does, without `@testable`,
// so it builds only while the edit API is public.
// The helpers that it calls build synthetic data; none of them takes or returns a type of the edit API.

/// Runs the editing example in the README; keep the two in sync.
@Suite struct PublicEditTests {
    @Test("A package client edits the contents of a note, and reads the result")
    func editContents() async throws {
        let folder = try NotesFolder.current()
        let store = TopoText.Store(root: folder.root)
        let note = try await store.note(for: #require(Note.ID("NOTE-GROCERIES")))
        // The contents of the note's row in `ZICNOTEDATA.ZDATA`, which a client reads for itself.
        let data = try storedData(RichNote.protobuf)

        let editor = NoteEditor()
        let edited = try editor.edit(
            data,
            of: note,
            applying: [
                .replaceText(.match(.init("hotel")), with: "hostel"),
                .setChecked(true, at: .containing("Book")),
                .appendParagraphs([.init("Call ahead", style: .checklist)]),
            ]
        )

        // The synthetic database gets the new contents as the note's newest row, and the store reads them.
        try folder.insert("INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (9000, 20, ?)", blob: edited)
        let paragraphs = try await store.content(for: note.id).paragraphs
        #expect(paragraphs.count == 7)
        #expect(paragraphs[2].runs.map(\.text).joined() == "Book hostel")
        #expect(paragraphs[2].style.kind == .checklist && paragraphs[2].style.isChecked)
        #expect(paragraphs[6].runs.map(\.text).joined() == "Call ahead")
        #expect(paragraphs[6].style.kind == .checklist && !paragraphs[6].style.isChecked)
        // The attachments are where they were.
        #expect(paragraphs[3].runs.compactMap(\.attachment).count == 3)
        #expect(paragraphs[4].runs.compactMap(\.attachment).count == 1)
    }

    @Test("A client builds each kind of edit, and names the replica")
    func buildEdits() throws {
        let anchors: [NoteEdit.ParagraphAnchor] = [.index(0), .containing("Trip")]
        let match = try NoteEdit.TextMatch("a", in: .index(1), occurrence: 2)
        #expect(match.text == "a" && match.paragraph == .index(1) && match.occurrence == 2)
        let plain = NoteEdit.NewParagraph("Milk")
        #expect(plain.text == "Milk" && plain.style == .body && !plain.isChecked)
        let paragraph = NoteEdit.NewParagraph("Eggs", style: .numbered)

        let edits: [NoteEdit] = try [
            .insertParagraphs([paragraph, .init("Tea", style: .bulleted)], at: .before(anchors[0])),
            .insertParagraphs([.init("Rice", style: .checklist, isChecked: true)], at: .after(anchors[1])),
            .insertParagraphs([.init("Salt")], at: .end),
            .insertText("!", at: .endOfParagraph(.index(0))),
            .insertText("Re: ", at: .startOfParagraph(.index(0))),
            .insertText("big ", at: .before(.init("bags"))),
            .insertText("s", at: .after(.init("hotel"))),
            .insertText("x", at: .offset(0)),
            .replaceText(.paragraphText(.containing("Pack")), with: "Pack light"),
            .replaceText(.range(0 ..< 1), with: "X"),
            .deleteText(.match(match)),
            .deleteParagraphs(.index(0), through: nil),
            .setChecked(false, at: .index(0)),
        ]
        #expect(Set(edits).count == edits.count)
        #expect(NoteEdit.appendParagraphs([paragraph]) == .insertParagraphs([paragraph], at: .end))

        let replica = UUID()
        var editor = NoteEditor(replica: replica)
        #expect(editor.replica == replica)
        editor.replica = UUID()
        #expect(editor.replica != replica)
    }

    @Test("A match that no note can have is refused when it is made")
    func invalidMatches() throws {
        #expect(throws: NoteEditError.emptyMatchText) { try NoteEdit.TextMatch("") }
        #expect(throws: NoteEditError.emptyMatchText) { try NoteEdit.TextMatch("", in: .index(0), occurrence: 1) }
        #expect(throws: NoteEditError.invalidOccurrence(0)) { try NoteEdit.TextMatch("a", occurrence: 0) }
        #expect(throws: NoteEditError.invalidOccurrence(-2)) { try NoteEdit.TextMatch("a", occurrence: -2) }
        #expect(try NoteEdit.TextMatch("a", occurrence: 1).occurrence == 1)
        // So an edit with such a match can't be built.
        #expect(throws: NoteEditError.emptyMatchText) { try NoteEdit.insertText("x", at: .before(.init(""))) }
        #expect(throws: NoteEditError.invalidOccurrence(0)) { try NoteEdit.deleteText(.match(.init("a", occurrence: 0))) }
    }

    @Test("New checklist items get identifiers of their own")
    func newItemIdentifiers() async throws {
        let folder = try NotesFolder.current()
        let note = try await TopoText.Store(root: folder.root).note(for: #require(Note.ID("NOTE-GROCERIES")))
        let items = (0 ..< 8).map { NoteEdit.NewParagraph("Item \($0)", style: .checklist) }
        let edited = try NoteEditor().edit(try storedData(RichNote.protobuf), of: note, applying: [.appendParagraphs(items)])
        // The fixture has two items, and each of the ten has another identifier.
        #expect(try checklistIdentifiers(in: edited).count == 10)
        #expect(Set(try checklistIdentifiers(in: edited)).count == 10)
    }

    @Test("Edits that insert other code units are other edits, and edits that find the same text are the same")
    func equality() async throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        let pairs: [(NoteEdit, NoteEdit)] = [
            (.insertText(composed, at: .offset(0)), .insertText(decomposed, at: .offset(0))),
            (.replaceText(.range(0 ..< 1), with: composed), .replaceText(.range(0 ..< 1), with: decomposed)),
            (.appendParagraphs([.init(composed)]), .appendParagraphs([.init(decomposed)])),
        ]
        let folder = try NotesFolder.current()
        let note = try await TopoText.Store(root: folder.root).note(for: #require(Note.ID("NOTE-GROCERIES")))
        let data = try storedData(RichNote.protobuf)
        for (first, second) in pairs {
            #expect(first != second)
            #expect(Set([first, second]).count == 2)
            #expect(Set([first, first]).count == 1)
            // The two give other contents, so they are not one edit.
            let results = try [first, second].map { try storedText(NoteEditor().edit(data, of: note, applying: [$0])).utf16.count }
            #expect(results[1] == results[0] + 1)
        }
        #expect(NoteEdit.NewParagraph(composed) != NoteEdit.NewParagraph(decomposed))
        #expect(Set([NoteEdit.NewParagraph(composed), .init(decomposed)]).count == 2)

        // A match finds either form, so the two matches are one.
        let same: (NoteEdit, NoteEdit) = try (.deleteText(.match(.init(composed))), .deleteText(.match(.init(decomposed))))
        #expect(same.0 == same.1 && same.0.hashValue == same.1.hashValue)
        #expect(NoteEdit.insertText("x", at: .offset(0)) != .replaceText(.range(0 ..< 0), with: "x"))
    }

    @Test("A client reads why an edit was not made")
    func refusals() async throws {
        let folder = try NotesFolder.current()
        let store = TopoText.Store(root: folder.root)
        let note = try await store.note(for: #require(Note.ID("NOTE-GROCERIES")))
        let locked = try await store.note(for: #require(Note.ID("NOTE-SECRET")))
        let data = try storedData(RichNote.protobuf)
        let editor = NoteEditor()

        #expect(throws: NoteEditError.noteLocked(locked.id)) { try editor.edit(data, of: locked, applying: []) }
        #expect(throws: NoteEditError.unreadableContent) { try editor.edit(Data("bplist00".utf8), of: note, applying: []) }
        #expect(throws: NoteEditError.ambiguousText("a", matches: 4)) {
            try editor.edit(data, of: note, applying: [.deleteText(.match(.init("a")))])
        }
        #expect(throws: NoteEditError.tableInRange) { try editor.edit(data, of: note, applying: [.deleteParagraphs(.index(4), through: nil)]) }
        // One edit that fails leaves none of the call's edits applied: the call returns no contents.
        #expect(throws: NoteEditError.paragraphNotFound(.index(40))) {
            try editor.edit(data, of: note, applying: [.insertText("x", at: .offset(0)), .setChecked(true, at: .index(40))])
        }

        // A document without merge state lacks a property that the engine relies on.
        let plain = try storedData(noteProtobuf([RunSpec(text: "Plain")]))
        do {
            _ = try editor.edit(plain, of: note, applying: [.appendParagraphs([.init("More")])])
            Issue.record("The edit was made")
        } catch NoteEditError.unsupportedDocument(let invariant) {
            #expect(invariant == .vectorTimestamp)
            #expect(NoteEditError.Invariant.allCases.contains(invariant))
            #expect(NoteEditError.unsupportedDocument(invariant).localizedDescription.contains(invariant.rawValue))
        }
    }
}
