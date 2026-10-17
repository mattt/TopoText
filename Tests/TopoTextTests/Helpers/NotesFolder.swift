@testable import TopoText
import Foundation
import SQLite3

/// A synthetic Notes folder with a `NoteStore.sqlite` database and a writer connection to it.
///
/// The database uses WAL journal mode and disables automatic checkpoints,
/// so that readers must read recent rows from the write-ahead log, as they do while Notes runs.
/// Every row is made up; none comes from a real Notes database.
/// Deinitialization closes the writer and removes the folder.
final class NotesFolder {
    let root: URL
    private(set) var writer: OpaquePointer?

    /// The database file.
    var database: URL { root.appendingPathComponent("NoteStore.sqlite") }

    /// Creates an empty folder with a database, and runs the schema SQL on it.
    init(schema: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topotext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(database.path, &writer) == SQLITE_OK else {
            throw NotesError.storeNotReadable
        }
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try execute(schema)
    }

    deinit {
        sqlite3_close(writer)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs SQL on the writer connection.
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(writer, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw NotesError.queryFailed(message.map { String(cString: $0) } ?? "")
        }
    }

    /// Runs an `INSERT` statement whose one placeholder is bound to a blob.
    func insert(_ sql: String, blob: Data) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NotesError.queryFailed(String(cString: sqlite3_errmsg(writer)))
        }
        _ = blob.withUnsafeBytes {
            sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NotesError.queryFailed(String(cString: sqlite3_errmsg(writer)))
        }
    }

    /// Closes the writer connection, which checkpoints the log into the main file.
    func closeWriter() {
        sqlite3_close(writer)
        writer = nil
    }

    /// Writes a file at a path relative to the folder, creating its folders.
    func writeFile(_ path: String, contents: String = "file") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}

extension NotesFolder {
    /// The UUID of the database in `Z_METADATA`.
    static let storeUUID = "6B1B5F0E-2D35-4C47-9C2B-5D0B0E6A1F00"

    /// A database with the current schema, with one account, folders of every kind,
    /// and notes that cover formatting, tables, attachments, and the rows that Notes doesn't list.
    static func current() throws -> NotesFolder {
        let folder = try NotesFolder(
            schema: """
                CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
                INSERT INTO Z_PRIMARYKEY VALUES (5, 'ICAttachment', 0, 0), (15, 'ICFolder', 0, 0), (11, 'ICMedia', 0, 0),
                    (12, 'ICNote', 0, 0), (14, 'ICAccount', 0, 0), (9, 'ICInlineAttachment', 0, 0);
                CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB);
                INSERT INTO Z_METADATA VALUES (1, '\(storeUUID)', NULL);
                CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                    Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER VARCHAR, ZMARKEDFORDELETION INTEGER,
                    ZTITLE1 VARCHAR, ZSNIPPET VARCHAR, ZWIDGETSNIPPET VARCHAR, ZFOLDER INTEGER, ZCREATIONDATE1 TIMESTAMP,
                    ZCREATIONDATE2 TIMESTAMP, ZCREATIONDATE3 TIMESTAMP, ZMODIFICATIONDATE1 TIMESTAMP, ZISPINNED INTEGER,
                    ZISPASSWORDPROTECTED INTEGER, ZISSYSTEMPAPER INTEGER,
                    ZTITLE2 VARCHAR, ZPARENT INTEGER, ZOWNER INTEGER, ZFOLDERTYPE INTEGER, ZSMARTFOLDERQUERYJSON VARCHAR,
                    ZNEEDSINITIALFETCHFROMCLOUD INTEGER, ZNAME VARCHAR,
                    ZTYPEUTI VARCHAR, ZTYPEUTI1 VARCHAR, ZALTTEXT VARCHAR, ZTOKENCONTENTIDENTIFIER VARCHAR, ZTITLE VARCHAR,
                    ZUSERTITLE VARCHAR, ZURLSTRING VARCHAR, ZSUMMARY VARCHAR, ZOCRSUMMARY VARCHAR, ZHANDWRITINGSUMMARY VARCHAR,
                    ZMEDIA INTEGER, ZFILENAME VARCHAR, ZGENERATION1 VARCHAR,
                    ZFALLBACKIMAGEGENERATION VARCHAR, ZFALLBACKPDFGENERATION VARCHAR,
                    ZMERGEABLEDATA BLOB, ZMERGEABLEDATA1 BLOB, ZNOTE INTEGER, ZNOTE1 INTEGER
                );
                CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNOTE INTEGER, ZDATA BLOB);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZNAME) VALUES (1, 14, 'ACCOUNT-1', 'iCloud');
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE2, ZOWNER, ZFOLDERTYPE, ZSMARTFOLDERQUERYJSON, ZNEEDSINITIALFETCHFROMCLOUD) VALUES
                    (2, 15, 'DefaultFolder-CloudKit', 'Notes', 1, 0, NULL, NULL),
                    (3, 15, 'TrashFolder-CloudKit', NULL, 1, NULL, NULL, NULL),
                    (4, 15, 'FOLDER-RECIPES', 'Recipes', 1, 0, '', 0),
                    (5, 15, 'FOLDER-SMART', 'Tagged', 1, 0, '{"tags":["groceries"]}', NULL),
                    (7, 15, 'FOLDER-PHANTOM', 'Phantom', 1, 0, NULL, 1),
                    (8, 15, 'FOLDER-GONE', 'Gone folder', 1, 0, NULL, NULL);
                UPDATE ZICCLOUDSYNCINGOBJECT SET ZMARKEDFORDELETION = 1 WHERE Z_PK = 8;
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE2, ZOWNER, ZFOLDERTYPE, ZPARENT) VALUES
                    (6, 15, 'FOLDER-DESSERTS', 'Desserts', 1, 0, 4);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZSNIPPET, ZWIDGETSNIPPET, ZFOLDER, ZCREATIONDATE1, ZCREATIONDATE3,
                    ZMODIFICATIONDATE1, ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZISSYSTEMPAPER) VALUES
                    (20, 12, 'NOTE-GROCERIES', 'Groceries', 'Plain bold and italic', NULL, 2, 1, 700000000, 800000000, 1, 0, 0, 0),
                    (21, 12, 'NOTE-PIE', 'Apple pie', NULL, 'Preheat the oven', 6, 700000000, NULL, 790000000, 0, 0, NULL, NULL),
                    (22, 12, 'NOTE-SECRET', 'Secret plans', 'Launch codes', NULL, 2, 700000000, NULL, 780000000, 0, 1, 0, 0),
                    (23, 12, 'NOTE-TRASHED', 'Old list', 'Something', NULL, 3, 700000000, NULL, 810000000, 0, 0, 0, 0),
                    (24, 12, 'NOTE-GONE', 'Gone', 'Purged', NULL, 2, 700000000, NULL, 820000000, 0, 0, 1, 0),
                    (25, 12, 'NOTE-CAFE', 'Café menu', 'Coffee', NULL, 4, 700000000, NULL, 770000000, 0, 0, 0, 0),
                    (26, 12, 'NOTE-DRAFT', NULL, NULL, NULL, NULL, 700000000, NULL, 830000000, 0, 0, 0, 1),
                    (27, 12, 'NOTE-UNFILED', 'Unfiled', 'No folder', NULL, NULL, 700000000, NULL, 840000000, 0, 0, 0, 1),
                    (28, 12, 'NOTE-TABLES', 'Tables', NULL, NULL, 2, 700000000, NULL, 760000000, 0, 0, 0, 0),
                    (29, 12, 'NOTE-PLIST', 'Property list', NULL, NULL, 2, 700000000, NULL, 750000000, 0, 0, 0, 0),
                    (40, 12, 'NOTE-UNSYNCED', 'Unsynced', NULL, NULL, 2, 700000000, NULL, NULL, 0, 0, 0, 0);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZFILENAME, ZGENERATION1) VALUES (30, 11, 'MEDIA-1', 'IMG_0001.jpeg', 'GEN-1');
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZTITLE, ZMEDIA, ZNOTE, ZOCRSUMMARY) VALUES
                    (31, 5, 'IMAGE-1', 'public.jpeg', 'Photo.jpeg', 30, 20, 'Receipt total 42');
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZTITLE, ZURLSTRING, ZNOTE) VALUES
                    (32, 5, 'URL-1', 'public.url', 'Example', 'https://example.com/page', 20);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI1, ZALTTEXT, ZNOTE1) VALUES
                    (33, 9, 'HASHTAG-1', 'com.apple.notes.inlinetextattachment.hashtag', '#groceries', 20);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI1, ZALTTEXT, ZTOKENCONTENTIDENTIFIER, ZNOTE1) VALUES
                    (34, 9, 'LINK-1', 'com.apple.notes.inlinetextattachment.link', 'Other note',
                        'applenotes:note/0e5a3c7d-1111-4b4b-8c8c-000000000001?ownerIdentifier=_abc', 20);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI1, ZALTTEXT, ZNOTE1) VALUES
                    (36, 9, 'HASHTAG-2', 'com.apple.notes.inlinetextattachment.hashtag', '#pantry', 28);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZSUMMARY, ZMERGEABLEDATA1, ZNOTE) VALUES
                    (37, 5, 'TABLE-BROKEN', 'com.apple.notes.table', 'Broken summary', X'1F8B0800000000000003FFFF', 28);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZMEDIA, ZNOTE, ZHANDWRITINGSUMMARY, ZFALLBACKIMAGEGENERATION) VALUES
                    (38, 5, 'DRAWING-1', 'com.apple.drawing.2', NULL, 28, 'Scribbled reminder', 'GEN-2');
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZTITLE, ZNOTE) VALUES
                    (41, 5, 'SECRET-IMAGE', 'public.png', 'Secret.png', 22);
                """
        )
        try folder.insert(
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZMERGEABLEDATA1, ZNOTE) VALUES (35, 5, 'TABLE-1', 'com.apple.notes.table', ?, 20)",
            blob: tableData([["Item", "Qty"], ["Milk", "1"], ["Eggs", "12"]])
        )
        try folder.insert(
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZMERGEABLEDATA1, ZNOTE) VALUES (39, 5, 'TABLE-2', 'com.apple.notes.table', ?, 28)",
            blob: tableData(
                [["Tag", "Pipe"], ["", "a|b"]],
                cellRuns: ["1,0": [RunSpec(text: "\u{FFFC}", attachment: ("HASHTAG-2", "com.apple.notes.inlinetextattachment.hashtag"))]],
                wrapCellsInRegisters: true
            )
        )
        let contents: [(Int, Int, Data)] = [
            (1, 20, noteData(groceries)),
            (2, 21, noteData([RunSpec(text: "Apple pie\n", style: 0), RunSpec(text: "Preheat the oven to 220°C\nUse Granny Smith apples")])),
            (3, 23, noteData([RunSpec(text: "Old list\nSomething")])),
            (4, 25, noteData([RunSpec(text: "Café menu\nCoffee\nCrème brûlée")])),
            // A newer row for the same note, as an edit can leave.
            (5, 21, noteData([RunSpec(text: "Apple pie\n", style: 0), RunSpec(text: "Newer: Bramley apples")])),
            (
                6, 28,
                noteData([
                    RunSpec(text: "Tables\n", style: 0),
                    RunSpec(text: "\u{FFFC}", attachment: ("TABLE-2", "com.apple.notes.table")),
                    RunSpec(text: "\n"),
                    RunSpec(text: "\u{FFFC}", attachment: ("TABLE-BROKEN", "com.apple.notes.table")),
                    RunSpec(text: "\n"),
                    RunSpec(text: "\u{FFFC}", attachment: ("DRAWING-1", "com.apple.drawing.2")),
                    RunSpec(text: " and missing "),
                    RunSpec(text: "\u{FFFC}", attachment: ("MISSING-1", "com.adobe.pdf")),
                ])
            ),
            // Some rows hold property lists rather than note contents.
            (7, 29, Data("bplist00".utf8) + Data(repeating: 0, count: 32)),
            (8, 22, Data([0x01, 0x02, 0x03])),
        ]
        for (row, note, data) in contents {
            try folder.insert("INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (\(row), \(note), ?)", blob: data)
        }
        return folder
    }

    /// The runs of the note `NOTE-GROCERIES`, which cover every paragraph style and most attachments.
    static let groceries = [
        RunSpec(text: "Groceries\n", style: 0),
        RunSpec(text: "Plain "),
        RunSpec(text: "bold", weight: 1),
        RunSpec(text: " and "),
        RunSpec(text: "italic ", weight: 2),
        RunSpec(text: "both", weight: 3),
        RunSpec(text: " 😀 "),
        RunSpec(text: "struck", strike: true),
        RunSpec(text: " "),
        RunSpec(text: "a link", link: "https://example.com"),
        RunSpec(text: "\n"),
        RunSpec(text: "Section\n", style: 1),
        RunSpec(text: "Sub\n", style: 2),
        RunSpec(text: "Milk\n", style: 103, checked: true),
        RunSpec(text: "Eggs\n", style: 103, checked: false),
        RunSpec(text: "First\n", style: 102),
        RunSpec(text: "Second\n", style: 102),
        RunSpec(text: "Nested\n", style: 102, indent: 1),
        RunSpec(text: "Third\n", style: 102),
        RunSpec(text: "Dot\n", style: 100),
        RunSpec(text: "Dash\n", style: 101, indent: 1),
        RunSpec(text: "let x = 1\n", style: 4),
        RunSpec(text: "let y = 2\n", style: 4),
        RunSpec(text: "Quoted\n", quote: true),
        RunSpec(text: "Tag "),
        RunSpec(text: "\u{FFFC}", attachment: ("HASHTAG-1", "com.apple.notes.inlinetextattachment.hashtag")),
        RunSpec(text: " and "),
        RunSpec(text: "\u{FFFC}", attachment: ("LINK-1", "com.apple.notes.inlinetextattachment.link")),
        RunSpec(text: "\n"),
        RunSpec(text: "\u{FFFC}", attachment: ("IMAGE-1", "public.jpeg")),
        RunSpec(text: "\n"),
        RunSpec(text: "\u{FFFC}", attachment: ("URL-1", "public.url")),
        RunSpec(text: "\n"),
        RunSpec(text: "\u{FFFC}", attachment: ("TABLE-1", "com.apple.notes.table")),
        RunSpec(text: "\n"),
        RunSpec(text: "Last line without newline"),
    ]

    /// A database with an older schema: no `Z_METADATA`, no newer note columns,
    /// tables in `ZMERGEABLEDATA`, and different entity numbers.
    static func older() throws -> NotesFolder {
        let folder = try NotesFolder(
            schema: """
                CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
                INSERT INTO Z_PRIMARYKEY VALUES (5, 'ICAttachment', 0, 0), (10, 'ICFolder', 0, 0), (12, 'ICNote', 0, 0), (14, 'ICAccount', 0, 0);
                CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                    Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER VARCHAR, ZMARKEDFORDELETION INTEGER,
                    ZTITLE1 VARCHAR, ZSNIPPET VARCHAR, ZFOLDER INTEGER, ZCREATIONDATE1 TIMESTAMP, ZMODIFICATIONDATE1 TIMESTAMP,
                    ZISPINNED INTEGER, ZISPASSWORDPROTECTED INTEGER, ZTITLE2 VARCHAR, ZOWNER INTEGER, ZFOLDERTYPE INTEGER, ZNAME VARCHAR,
                    ZTYPEUTI VARCHAR, ZMERGEABLEDATA BLOB, ZNOTE INTEGER, ZMEDIA INTEGER, ZFILENAME VARCHAR
                );
                CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNOTE INTEGER, ZDATA BLOB);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZNAME) VALUES (1, 14, 'LocalAccount', 'On My Mac');
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE2, ZOWNER, ZFOLDERTYPE) VALUES (2, 10, 'DefaultFolder-Local', 'Notes', 1, 0);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZSNIPPET, ZFOLDER, ZCREATIONDATE1, ZMODIFICATIONDATE1) VALUES
                    (3, 12, 'OLD-NOTE', 'Old note', 'Old snippet', 2, 600000000, 650000000);
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZFILENAME) VALUES (5, 11, 'OLD-MEDIA', 'scan.pdf');
                INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZMEDIA, ZNOTE) VALUES (6, 5, 'OLD-PDF', 'com.adobe.pdf', 5, 3);
                """
        )
        try folder.insert(
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZMERGEABLEDATA, ZNOTE) VALUES (4, 5, 'OLD-TABLE', 'com.apple.notes.table', ?, 3)",
            blob: tableData([["A", "B"]])
        )
        try folder.insert(
            "INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (1, 3, ?)",
            blob: noteData([
                RunSpec(text: "Old note\n", style: 0),
                RunSpec(text: "\u{FFFC}", attachment: ("OLD-TABLE", "com.apple.notes.table")),
            ])
        )
        return folder
    }
}

extension Identifier {
    /// Returns an identifier for a string that is known not to be empty.
    static func id(_ string: String) -> Self {
        Self(string)!
    }
}
