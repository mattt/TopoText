@testable import TopoText
import Foundation
import Testing

/// A box that lets a test move a value out of a `@Sendable` closure on purpose.
final class Leak<Value>: @unchecked Sendable {
    var value: Value?
}

@Suite struct StoreTests {
    let folder: NotesFolder
    let store: Store

    init() throws {
        folder = try NotesFolder.current()
        store = Store(root: folder.root)
    }

    func identifiers(_ request: Note.FetchRequest) async throws -> [String] {
        try await store.search(request).notes.map(\.id.description)
    }

    // MARK: Accounts and folders

    @Test("Accounts are listed with their names")
    func accounts() async throws {
        #expect(try await store.accounts() == [Account(id: .id("ACCOUNT-1"), name: "iCloud")])
    }

    @Test("Folders leave out smart, unfetched, and deleted folders")
    func folders() async throws {
        let folders = try await store.folders()
        #expect(folders.map(\.name) == ["Desserts", "Notes", "Recipes", "Recently Deleted"])
        #expect(folders.map(\.noteCount) == [1, 5, 1, 1])
        #expect(folders[0].parentID == .id("FOLDER-RECIPES"))
        #expect(folders.allSatisfy { $0.account == Account(id: .id("ACCOUNT-1"), name: "iCloud") })
        #expect(folders.map(\.isRecentlyDeleted) == [false, false, false, true])
        // Recently Deleted is found by its identifier when its type is missing, and named in English when its title is.
        #expect(folders[3].id == .id("TrashFolder-CloudKit"))
    }

    // MARK: Listing

    @Test("Notes are listed newest first, without Recently Deleted or notes that Notes doesn't list")
    func listing() async throws {
        #expect(
            try await identifiers(.init()) == [
                "NOTE-GROCERIES", "NOTE-PIE", "NOTE-SECRET", "NOTE-CAFE", "NOTE-TABLES", "NOTE-PLIST", "NOTE-UNSYNCED",
            ]
        )
    }

    @Test("Cursors page through the results")
    func paging() async throws {
        var request = Note.FetchRequest(limit: 3)
        var pages: [[String]] = []
        while true {
            let result = try await store.search(request)
            pages.append(result.notes.map(\.id.description))
            guard let cursor = result.nextCursor else { break }
            #expect(Note.FetchRequest.Cursor(cursor.description) == cursor)
            request.cursor = cursor
        }
        #expect(
            pages == [
                ["NOTE-GROCERIES", "NOTE-PIE", "NOTE-SECRET"],
                ["NOTE-CAFE", "NOTE-TABLES", "NOTE-PLIST"],
                ["NOTE-UNSYNCED"],
            ]
        )
    }

    @Test("A page that ends with the last note has no cursor")
    func exactPage() async throws {
        let result = try await store.search(.init(limit: 7))
        #expect(result.notes.count == 7)
        #expect(result.nextCursor == nil)
    }

    @Test("Folder filters search only the named folders, including Recently Deleted")
    func folderFilter() async throws {
        #expect(try await identifiers(.init(folderIDs: [.id("FOLDER-DESSERTS")])) == ["NOTE-PIE"])
        #expect(try await identifiers(.init(folderIDs: [.id("TrashFolder-CloudKit")])) == ["NOTE-TRASHED"])
        #expect(try await identifiers(.init(folderIDs: [.id("FOLDER-DESSERTS"), .id("FOLDER-RECIPES")])) == ["NOTE-PIE", "NOTE-CAFE"])
        #expect(try await identifiers(.init(includesRecentlyDeleted: true, limit: 2)) == ["NOTE-TRASHED", "NOTE-GROCERIES"])
    }

    @Test("A folder that Notes doesn't list is not found", arguments: ["FOLDER-SMART", "FOLDER-PHANTOM", "FOLDER-GONE", "NOPE"])
    func unlistedFolder(identifier: String) async throws {
        await #expect(throws: NotesError.folderNotFound(.id(identifier))) {
            try await store.search(.init(folderIDs: [.id("FOLDER-RECIPES"), .id(identifier)]))
        }
    }

    @Test("Dates filter by modification date, with an exclusive end")
    func dateRange() async throws {
        let request = Note.FetchRequest(
            startDate: Date(timeIntervalSinceReferenceDate: 770_000_000),
            endDate: Date(timeIntervalSinceReferenceDate: 790_000_000)
        )
        #expect(try await identifiers(request) == ["NOTE-SECRET", "NOTE-CAFE"])
    }

    @Test("Invalid requests are rejected")
    func validation() async throws {
        await #expect(throws: Note.FetchRequest.ValidationError.limitOutOfRange) { try await store.search(.init(limit: 0)) }
        await #expect(throws: Note.FetchRequest.ValidationError.limitOutOfRange) { try await store.search(.init(limit: 101)) }
        await #expect(throws: Note.FetchRequest.ValidationError.scanLimitOutOfRange) { try await store.search(.init(scanLimit: 0)) }
        let date = Date(timeIntervalSinceReferenceDate: 780_000_000)
        await #expect(throws: Note.FetchRequest.ValidationError.invalidDateRange) {
            try await store.search(.init(startDate: date, endDate: date))
        }
    }

    @Test("A cursor from another database is rejected")
    func foreignCursor() async throws {
        let cursor = try #require(Note.FetchRequest.Cursor("OTHER-STORE:800000000.0:20"))
        await #expect(throws: NotesError.storeChanged) { try await store.search(.init(cursor: cursor)) }
    }

    // MARK: Search

    @Test(
        "Search matches titles, previews, and contents without regard to case or diacritics",
        arguments: [
            ("bramley", ["NOTE-PIE"]),  // the newest contents of the note
            ("granny", []),  // older contents are ignored
            ("preheat", ["NOTE-PIE"]),  // the widget preview
            ("#GROCERIES", ["NOTE-GROCERIES"]),  // a tag
            ("#pantry", ["NOTE-TABLES"]),  // a tag in a table cell
            ("eggs", ["NOTE-GROCERIES"]),
            ("12", ["NOTE-GROCERIES"]),  // a table cell
            ("other note", ["NOTE-GROCERIES"]),  // a link to another note
            ("example.com/page", ["NOTE-GROCERIES"]),  // a link card
            ("photo.jpeg", ["NOTE-GROCERIES"]),  // an attachment's title
            ("receipt total", ["NOTE-GROCERIES"]),  // text recognized in an image
            ("scribbled", ["NOTE-TABLES"]),  // handwriting
            ("broken summary", ["NOTE-TABLES"]),  // the summary of a table that can't be decoded
            ("secret", ["NOTE-SECRET"]),  // a locked note's title
            ("launch codes", []),  // a locked note's preview is hidden
            ("creme brulee", ["NOTE-CAFE"]),
            ("something", []),  // Recently Deleted is left out
            ("no folder", []),  // notes without a folder are left out
        ]
    )
    func search(query: String, expected: [String]) async throws {
        #expect(try await identifiers(.init(query: query)) == expected)
    }

    @Test("Search reports notes whose contents can't be decoded")
    func unreadable() async throws {
        let result = try await store.search(.init(query: "zzz"))
        #expect(result.notes.isEmpty)
        #expect(result.unreadableNoteIDs == [.id("NOTE-PLIST")])
        #expect(result.scannedNoteCount == 7)
        #expect(result.nextCursor == nil)
        // A title still matches.
        #expect(try await identifiers(.init(query: "property")) == ["NOTE-PLIST"])
    }

    @Test("Search stops at the scan limit and continues from its cursor")
    func scanLimit() async throws {
        var request = Note.FetchRequest(query: "coffee", scanLimit: 2)
        var pages: [[String]] = []
        var scanned: [Int] = []
        while true {
            let result = try await store.search(request)
            pages.append(result.notes.map(\.id.description))
            scanned.append(result.scannedNoteCount)
            guard let cursor = result.nextCursor else { break }
            request.cursor = cursor
        }
        #expect(pages == [[], ["NOTE-CAFE"], [], []])
        #expect(scanned == [2, 2, 2, 1])
    }

    @Test("Search stops when it has enough matches")
    func searchLimit() async throws {
        let first = try await store.search(.init(query: "e", limit: 2))
        #expect(first.notes.map(\.id.description) == ["NOTE-GROCERIES", "NOTE-PIE"])
        #expect(first.scannedNoteCount == 2)
        let cursor = try #require(first.nextCursor)
        #expect(try await identifiers(.init(query: "e", limit: 2, cursor: cursor)) == ["NOTE-SECRET", "NOTE-CAFE"])
    }

    @Test("A query of white space matches every note")
    func blankQuery() async throws {
        let result = try await store.search(.init(query: " \n", limit: 2))
        #expect(result.notes.map(\.id.description) == ["NOTE-GROCERIES", "NOTE-PIE"])
        #expect(result.nextCursor != nil)
    }

    // MARK: Notes

    @Test("A note has its metadata")
    func note() async throws {
        let groceries = try await store.note(for: .id("NOTE-GROCERIES"))
        #expect(groceries.title == "Groceries")
        #expect(groceries.snippet == "Plain bold and italic")
        #expect(groceries.folderID == .id("DefaultFolder-CloudKit"))
        #expect(groceries.isPinned && !groceries.isLocked && !groceries.isRecentlyDeleted)
        // The creation date prefers ZCREATIONDATE3.
        #expect(groceries.creationDate == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(groceries.modificationDate == Date(timeIntervalSinceReferenceDate: 800_000_000))

        let pie = try await store.note(for: .id("NOTE-PIE"))
        #expect(pie.creationDate == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(pie.snippet == "Preheat the oven")

        let secret = try await store.note(for: .id("NOTE-SECRET"))
        #expect(secret.isLocked)
        #expect(secret.snippet == nil)

        #expect(try await store.note(for: .id("NOTE-TRASHED")).isRecentlyDeleted)
        #expect(try await store.note(for: .id("NOTE-UNSYNCED")).modificationDate == nil)
    }

    @Test("Notes that Notes doesn't list are not found", arguments: ["NOTE-GONE", "NOTE-DRAFT", "NOTE-UNFILED", "IMAGE-1", "NOPE"])
    func unlistedNote(identifier: String) async throws {
        await #expect(throws: NotesError.noteNotFound(.id(identifier))) { try await store.note(for: .id(identifier)) }
        await #expect(throws: NotesError.noteNotFound(.id(identifier))) { try await store.content(for: .id(identifier)) }
    }

    // MARK: Content

    @Test("Contents resolve attachments")
    func contentAttachments() async throws {
        let content = try await store.content(for: .id("NOTE-GROCERIES"))
        let attachments = content.paragraphs.flatMap(\.runs).compactMap(\.attachment)
        #expect(attachments.map(\.kind) == [.hashtag, .noteLink, .image, .webLink, .table])

        #expect(attachments[0].displayText == "#groceries")
        #expect(attachments[1].displayText == "Other note")
        #expect(attachments[1].linkedNoteID == .id("0E5A3C7D-1111-4B4B-8C8C-000000000001"))
        #expect(attachments[2].fileName == "IMG_0001.jpeg")
        #expect(attachments[2].title == "Photo.jpeg")
        #expect(attachments[2].recognizedText == "Receipt total 42")
        #expect(attachments[3].url == URL(string: "https://example.com/page"))
        #expect(attachments[3].title == "Example")
        let table = try #require(attachments[4].table)
        #expect(table.rows.map { $0.map { $0.paragraphs.map(\.text) } } == [[["Item"], ["Qty"]], [["Milk"], ["1"]], [["Eggs"], ["12"]]])
    }

    @Test("Attachments in table cells resolve, and an undecodable table keeps its summary")
    func nestedAttachments() async throws {
        let content = try await store.content(for: .id("NOTE-TABLES"))
        let attachments = content.paragraphs.flatMap(\.runs).compactMap(\.attachment)
        #expect(attachments.map(\.id.description) == ["TABLE-2", "TABLE-BROKEN", "DRAWING-1", "MISSING-1"])
        let cell = try #require(attachments[0].table?.rows[1][0].paragraphs.first?.runs.first?.attachment)
        #expect(cell.displayText == "#pantry")
        #expect(attachments[1].table == nil)
        #expect(attachments[1].summary == "Broken summary")
        #expect(attachments[2].handwritingText == "Scribbled reminder")
        #expect(attachments[3] == Note.Attachment(id: .id("MISSING-1"), typeIdentifier: "com.adobe.pdf"))
    }

    @Test("Contents that can't be read throw")
    func contentErrors() async throws {
        await #expect(throws: NotesError.noteLocked(.id("NOTE-SECRET"))) { try await store.content(for: .id("NOTE-SECRET")) }
        await #expect(throws: NotesError.unsupportedContent(.id("NOTE-PLIST"))) { try await store.content(for: .id("NOTE-PLIST")) }
        await #expect(throws: NotesError.contentNotFound(.id("NOTE-UNSYNCED"))) { try await store.content(for: .id("NOTE-UNSYNCED")) }
    }

    @Test("Damaged contents are malformed")
    func malformedContent() async throws {
        try folder.execute("UPDATE ZICNOTEDATA SET ZDATA = X'1F8B08000000000000030102030405060708' WHERE ZNOTE = 25")
        await #expect(throws: NotesError.malformedContent(.id("NOTE-CAFE"))) { try await store.content(for: .id("NOTE-CAFE")) }
        #expect(try await store.search(.init(query: "zzz")).unreadableNoteIDs == [.id("NOTE-CAFE"), .id("NOTE-PLIST")])
    }

    // MARK: Snapshots and the store

    @Test("A snapshot reads several queries, and is invalid after its closure returns")
    func snapshot() async throws {
        let leak = Leak<Store.Snapshot>()
        let (count, text) = try await store.withSnapshot { snapshot in
            leak.value = snapshot
            let folders = try snapshot.folders()
            let note = try snapshot.search(.init(folderIDs: [folders[0].id])).notes[0]
            return (folders.count, try snapshot.content(for: note.id).paragraphs.first?.text)
        }
        #expect(count == 4)
        #expect(text == "Apple pie")
        #expect(throws: NotesError.connectionClosed) { try leak.value?.folders() }
    }

    @Test("Operations run on the store's queue")
    func queue() async throws {
        let label = try await store.withSnapshot { _ in String(cString: __dispatch_queue_get_label(nil)) }
        #expect(label == "me.mattt.TopoText.store")
    }

    @Test("A canceled task stops before reading")
    func cancellation() async throws {
        let store = self.store
        let error = await Task { () async -> (any Error)? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.folders()
                return nil
            } catch {
                return error
            }
        }.value
        #expect(error is CancellationError)
    }

    @Test("An operation stops at the time limit")
    func timeLimit() async throws {
        let store = Store(root: folder.root, configuration: try .init(timeLimit: .nanoseconds(1)))
        await #expect(throws: NotesError.timedOut) { try await store.checkAccess() }
        #expect(throws: Store.Configuration.ValidationError.invalidTimeLimit) { try Store.Configuration(timeLimit: .zero) }
    }

    @Test("Without a write-ahead log, a read-only folder is read through the main file")
    func readOnlyFolder() async throws {
        // The system SQLite keeps the log files after the last connection closes, so remove them.
        folder.closeWriter()
        try FileManager.default.removeItem(atPath: folder.database.path + "-wal")
        try FileManager.default.removeItem(atPath: folder.database.path + "-shm")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.root.path)
        #expect(try await store.folders().count == 4)
        #expect(try await identifiers(.init(query: "bramley")) == ["NOTE-PIE"])
        #expect(!FileManager.default.fileExists(atPath: folder.database.path + "-shm"))
    }
}

@Suite struct StoreLocationTests {
    @Test("A folder without a database is not a store")
    func emptyFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topotext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: NotesError.storeNotFound) { try await Store(root: root).checkAccess() }

        try Data("not a database".utf8).write(to: root.appendingPathComponent("NoteStore.sqlite"))
        await #expect(throws: NotesError.storeNotReadable) { try await Store(root: root).checkAccess() }
    }

    @Test("A folder that can't be read is not readable")
    func missingFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topotext-\(UUID().uuidString)")
        await #expect(throws: NotesError.storeNotReadable) { try await Store(root: root).checkAccess() }
    }

    @Test("A database without the Notes tables has an unsupported schema")
    func unsupportedSchema() async throws {
        let folder = try NotesFolder(schema: "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY);")
        await #expect(throws: NotesError.unsupportedSchema) { try await Store(root: folder.root).checkAccess() }

        let noEntities = try NotesFolder(
            schema: """
                CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR);
                CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER VARCHAR);
                CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZDATA BLOB);
                """
        )
        await #expect(throws: NotesError.unsupportedSchema) { try await Store(root: noEntities.root).checkAccess() }
    }

    @Test("The default folder is in the user's group containers")
    func defaultRoot() {
        #expect(Store.defaultRoot.path.hasSuffix("/Library/Group Containers/group.com.apple.notes"))
        #expect(Store(configuration: .default).root == Store.defaultRoot)
    }
}

@Suite struct OlderSchemaTests {
    let folder: NotesFolder
    let store: Store

    init() throws {
        folder = try NotesFolder.older()
        store = Store(root: folder.root)
    }

    @Test("An older schema reads with the columns it has")
    func olderSchema() async throws {
        #expect(try await store.accounts() == [Account(id: .id("LocalAccount"), name: "On My Mac")])
        #expect(try await store.folders().map(\.name) == ["Notes"])
        let result = try await store.search(.init(query: "b"))
        #expect(result.notes.map(\.id.description) == ["OLD-NOTE"])
        #expect(result.notes[0].creationDate == Date(timeIntervalSinceReferenceDate: 600_000_000))
        #expect(result.notes[0].snippet == "Old snippet")
        let content = try await store.content(for: .id("OLD-NOTE"))
        #expect(Renderer(format: .markdown).render(content) == "# Old note\n\n| A | B |\n| --- | --- |")
    }

    @Test("Cursors work without database metadata")
    func cursorWithoutMetadata() async throws {
        let result = try await store.search(.init(limit: 1))
        #expect(result.nextCursor == nil)
        let cursor = Note.FetchRequest.Cursor(after: result.notes[0])
        #expect(cursor.description.hasPrefix(":"))
        #expect(Note.FetchRequest.Cursor(cursor.description) == cursor)
        #expect(try await store.search(.init(cursor: cursor)).notes.isEmpty)
    }
}
