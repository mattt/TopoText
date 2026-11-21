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

    @Test("A client builds each kind of edit, and names the replica and the identifiers")
    func buildEdits() throws {
        let anchors: [NoteEdit.ParagraphAnchor] = [.index(0), .containing("Trip")]
        let match = NoteEdit.TextMatch("a", in: .index(1), occurrence: 2)
        #expect(match.text == "a" && match.paragraph == .index(1) && match.occurrence == 2)
        var paragraph = NoteEdit.NewParagraph("Milk")
        #expect(paragraph.style == .body && !paragraph.isChecked)
        paragraph.style = .numbered
        paragraph.text = "Eggs"
        paragraph.isChecked = true

        let edits: [NoteEdit] = [
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
        var editor = NoteEditor(replica: replica, makeIdentifier: { replica })
        #expect(editor.replica == replica && editor.makeIdentifier() == replica)
        editor.replica = UUID()
        editor.makeIdentifier = { UUID() }
        #expect(editor.replica != replica)
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
