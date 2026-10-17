@testable import TopoText
import Foundation
import Testing

@Suite struct IdentifierTests {
    @Test("Identifiers round-trip through their string form and encode as it")
    func roundTrip() throws {
        let id = try #require(Note.ID("0E5A3C7D-1111-4B4B-8C8C-000000000001"))
        #expect(Note.ID(id.description) == id)
        #expect(Folder.ID("") == nil)

        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["0E5A3C7D-1111-4B4B-8C8C-000000000001"]"#)
        #expect(try JSONDecoder().decode([Note.ID].self, from: data) == [id])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([Note.ID].self, from: Data(#"[""]"#.utf8)) }
    }

    @Test(
        "Links to notes give the note's identifier",
        arguments: [
            ("applenotes:note/0e5a3c7d-1111-4b4b-8c8c-000000000001?ownerIdentifier=_abc", "0E5A3C7D-1111-4B4B-8C8C-000000000001"),
            ("applenotes:note/0E5A3C7D-1111-4B4B-8C8C-000000000001", "0E5A3C7D-1111-4B4B-8C8C-000000000001"),
            ("applenotes://note/ABC-123", "ABC-123"),
            ("APPLENOTES:note/abc", "ABC"),
        ]
    )
    func noteLink(link: String, identifier: String) {
        #expect(noteID(inLink: link) == Note.ID(identifier))
    }

    @Test(
        "Other links give no identifier",
        arguments: ["https://example.com/note/ABC", "applenotes:folder/ABC", "applenotes:note/", "applenotes:note/xyz", "applenotes:note/A/B", ""]
    )
    func otherLink(link: String) {
        #expect(noteID(inLink: link) == nil)
    }

    @Test("Runs and inline links give the identifier of the note they open")
    func linkedNoteID() {
        let link = "applenotes:note/0e5a3c7d-1111-4b4b-8c8c-000000000001"
        #expect(Note.TextRun(text: "x", link: link).linkedNoteID == .id("0E5A3C7D-1111-4B4B-8C8C-000000000001"))
        #expect(Note.TextRun(text: "x", link: "https://example.com").linkedNoteID == nil)
        let inline = Note.Attachment(id: .id("A"), typeIdentifier: "com.apple.notes.inlinetextattachment.link", tokenIdentifier: link)
        #expect(inline.linkedNoteID == .id("0E5A3C7D-1111-4B4B-8C8C-000000000001"))
        // Only inline links link to notes.
        let tag = Note.Attachment(id: .id("B"), typeIdentifier: "com.apple.notes.inlinetextattachment.hashtag", tokenIdentifier: link)
        #expect(tag.linkedNoteID == nil)
    }

    @Test("Cursors parse only their own string form")
    func cursors() throws {
        let cursor = try #require(Note.FetchRequest.Cursor("STORE:800000000.0:20"))
        #expect(cursor.description == "STORE:800000000.0:20")
        #expect(Note.FetchRequest.Cursor("STORE:-1e+308:20") != nil)
        for invalid in ["", "STORE:1.0", "STORE:x:20", "STORE:1.0:0", "STORE:inf:20", "STORE:nan:20", "A:1.0:2:3"] {
            #expect(Note.FetchRequest.Cursor(invalid) == nil)
        }
        let data = try JSONEncoder().encode(cursor)
        #expect(try JSONDecoder().decode(Note.FetchRequest.Cursor.self, from: data) == cursor)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Note.FetchRequest.Cursor.self, from: Data(#""bad""#.utf8)) }
    }
}
