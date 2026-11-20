@testable import TopoText
import Foundation
import Testing

@Suite struct InlineTests {
    let folder: NotesFolder
    let store: Store

    init() throws {
        folder = try NotesFolder.current()
        store = Store(root: folder.root)
    }

    static let target = Note.ID("0E5A3C7D-1111-4B4B-8C8C-000000000001")!

    // MARK: Smart folders

    @Test("Smart folders are listed with their queries, and the folders that hold none are not")
    func smartFolders() async throws {
        let smartFolders = try await store.smartFolders()
        #expect(smartFolders.map(\.name) == ["Pinned", "Tagged"])
        #expect(smartFolders.map(\.id.description) == ["FOLDER-SMART-2", "FOLDER-SMART"])
        #expect(smartFolders[0].query == #"{"entity":"note","type":{"and":[{"deleted":false},{"pinned":true}]}}"#)
        #expect(smartFolders[0].parentID == .id("FOLDER-RECIPES"))
        #expect(smartFolders[1].query == #"{"tags":["groceries"]}"#)
        #expect(smartFolders[1].parentID == nil)
        #expect(smartFolders.allSatisfy { $0.account == Account(id: .id("ACCOUNT-1"), name: "iCloud") })
    }

    // MARK: Tags

    @Test("A note's tags come from its tag attachments, without repeats or deleted rows")
    func noteTags() async throws {
        let tags = try await store.tags(for: [.id("NOTE-GROCERIES"), .id("NOTE-PIE"), .id("NOTE-CAFE"), .id("NOTE-TABLES")])
        #expect(tags[.id("NOTE-GROCERIES")]?.map(\.text) == ["#groceries"])
        #expect(tags[.id("NOTE-PIE")]?.map(\.text) == ["#Groceries"])
        // A tag with no name is skipped, and spellings that differ in case or accents are one tag.
        #expect(tags[.id("NOTE-CAFE")]?.map(\.text) == ["#Café"])
        #expect(tags[.id("NOTE-TABLES")]?.map(\.text) == ["#pantry"])
    }

    @Test("Locked notes, Recently Deleted notes, and unknown notes have no tags")
    func hiddenTags() async throws {
        let tags = try await store.tags(for: [.id("NOTE-SECRET"), .id("NOTE-TRASHED"), .id("NOTE-GONE"), .id("NOPE")])
        #expect(tags.isEmpty)
        #expect(try await store.tags(for: []).isEmpty)
    }

    @Test("Tags are counted by note, ignoring case, with the spelling of the newest note")
    func tagSummaries() async throws {
        let summaries = try await store.tags()
        #expect(summaries.map(\.tag.text) == ["#groceries", "#Café", "#pantry"])
        // The note that spells the tag three ways counts once.
        #expect(summaries.map(\.noteCount) == [2, 1, 1])
    }

    @Test("Without a column that marks locked notes, tag and link reads report an unsupported schema")
    func noLockColumn() async throws {
        try folder.execute("ALTER TABLE ZICCLOUDSYNCINGOBJECT DROP COLUMN ZISPASSWORDPROTECTED")
        await #expect(throws: NotesError.unsupportedSchema) { try await store.tags(for: [.id("NOTE-GROCERIES")]) }
        await #expect(throws: NotesError.unsupportedSchema) { try await store.tags() }
        await #expect(throws: NotesError.unsupportedSchema) { try await store.links(from: [.id("NOTE-GROCERIES")]) }
        await #expect(throws: NotesError.unsupportedSchema) { try await store.backlinks(to: Self.target) }
    }

    @Test("Recently Deleted notes count when asked")
    func tagSummariesIncludingDeleted() async throws {
        let summaries = try await store.tags(includingRecentlyDeleted: true)
        #expect(summaries.map(\.tag.name) == ["groceries", "Café", "old", "pantry"])
    }

    @Test("A tag is written with its leading hash, and the hash is optional")
    func tagText() {
        #expect(Note.Tag("#groceries") == Note.Tag("groceries"))
        #expect(Note.Tag("  ##groceries ")?.name == "groceries")
        #expect(Note.Tag("#") == nil)
        #expect(Note.Tag("")?.text == nil)
    }

    // MARK: Links

    @Test("A note's links to other notes have their targets and labels")
    func noteLinks() async throws {
        let links = try await store.links(from: [.id("NOTE-GROCERIES"), .id("NOTE-PIE"), .id("NOTE-CAFE")])
        #expect(links[.id("NOTE-GROCERIES")] == [Note.Link(sourceID: .id("NOTE-GROCERIES"), targetID: Self.target, label: "Other note")])
        #expect(links[.id("NOTE-PIE")] == [Note.Link(sourceID: .id("NOTE-PIE"), targetID: Self.target, label: "Apple pie to other")])
        // The link to a web address is not a link to a note.
        #expect(links[.id("NOTE-CAFE")] == nil)
    }

    @Test("Backlinks list the notes that link to a note, newest first, without locked notes")
    func backlinks() async throws {
        let links = try await store.backlinks(to: Self.target)
        #expect(links.map(\.sourceID.description) == ["NOTE-GROCERIES", "NOTE-PIE"])
        #expect(try await store.backlinks(to: .id("NOTE-GROCERIES")).isEmpty)
    }

    @Test("A note's link to itself is one of its links but not one of its backlinks")
    func selfLink() async throws {
        let id = "0E5A3C7D-2222-4B4B-8C8C-000000000002"
        try folder.execute(
            """
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMODIFICATIONDATE1, ZISPASSWORDPROTECTED) VALUES
                (70, 12, '\(id)', 'Linked', 2, 700000000, 0);
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI1, ZALTTEXT, ZTOKENCONTENTIDENTIFIER, ZNOTE1, ZMARKEDFORDELETION) VALUES
                (71, 9, 'LINK-SELF', 'com.apple.notes.inlinetextattachment.link', 'Myself', 'applenotes:note/\(id.lowercased())', 70, 0),
                (72, 9, 'LINK-IN', 'com.apple.notes.inlinetextattachment.link', 'Linked', 'applenotes://note/\(id)?ownerIdentifier=_abc', 21, 0);
            """
        )
        let target = Note.ID.id(id)
        #expect(try await store.links(from: [target])[target] == [Note.Link(sourceID: target, targetID: target, label: "Myself")])
        #expect(try await store.backlinks(to: target) == [Note.Link(sourceID: .id("NOTE-PIE"), targetID: target, label: "Linked")])
    }

    @Test("A backlink target with LIKE wildcards matches only itself")
    func backlinkWildcards() async throws {
        #expect(try await store.backlinks(to: .id("%")).isEmpty)
        #expect(try await store.backlinks(to: .id("0E5A3C7D_1111%")).isEmpty)
        #expect(Database.escapedForLike(#"a%b_c\d"#) == #"a\%b\_c\\d"#)
    }

    @Test("The queries read one snapshot together")
    func snapshot() async throws {
        let (smartCount, tagCount, backlinkCount) = try await store.withSnapshot { snapshot in
            (try snapshot.smartFolders().count, try snapshot.tags().count, try snapshot.backlinks(to: Self.target).count)
        }
        #expect((smartCount, tagCount, backlinkCount) == (2, 3, 2))
    }
}
