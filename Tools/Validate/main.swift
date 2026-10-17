import Foundation
import SQLite3
import TopoText

// Reads a real Notes database with TopoText and prints aggregate counts,
// so that the decoders can be checked against real data without revealing it.
// The output never contains titles, text, identifiers, file names, or type identifiers.
//
// Usage: swift run Validate [<path to group.com.apple.notes>] [--applescript]
//
// The process that runs this tool needs read access to the Notes folder,
// for example through Full Disk Access for the terminal.
// With --applescript, the tool also asks Notes for its count of notes,
// which needs permission to control Notes.

/// Counts of what the tool found, keyed by a label that describes the count.
struct Tally: Sendable {
    private(set) var counts: [String: Int] = [:]
    private(set) var decodingTime: Duration = .zero

    mutating func add(_ label: String, _ amount: Int = 1) {
        counts[label, default: 0] += amount
    }

    mutating func merge(_ other: Tally) {
        counts.merge(other.counts, uniquingKeysWith: +)
        decodingTime += other.decodingTime
    }

    subscript(label: String) -> Int {
        counts[label] ?? 0
    }

    /// Reads a note's contents and counts what they hold.
    mutating func examine(_ note: Note, in snapshot: Store.Snapshot) throws {
        add("notes")
        if note.isRecentlyDeleted { add("notes in Recently Deleted") }
        if note.isPinned { add("pinned notes") }
        if note.title.isEmpty { add("notes with an empty title") }
        if note.modificationDate == nil { add("notes without a modification date") }
        if note.creationDate == nil { add("notes without a creation date") }
        if note.snippet == nil { add("notes without a preview") }
        guard !note.isLocked else {
            add("locked notes")
            return
        }

        let start = ContinuousClock.now
        let content: Note.Content
        do {
            content = try snapshot.content(for: note.id)
        } catch let error as NotesError {
            add("contents: \(Self.name(of: error))")
            return
        }
        decodingTime += ContinuousClock.now - start
        add("contents: decoded")

        // Notes takes the title from the first line, and can shorten it.
        let firstLine = (content.paragraphs.first?.text ?? "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if firstLine == title {
            add("titles: same as the first line")
        } else if !title.isEmpty, firstLine.hasPrefix(title) {
            add("titles: a prefix of the first line")
        } else {
            add("titles: different from the first line")
        }
        if content.paragraphs.isEmpty { add("decoded notes without paragraphs") }

        try examine(content, in: snapshot, depth: 0)
    }

    private mutating func examine(_ content: Note.Content, in snapshot: Store.Snapshot, depth: Int) throws {
        let place = depth == 0 ? "" : " in table cells"
        for paragraph in content.paragraphs {
            add("paragraphs\(place): \(paragraph.style.kind)")
            if paragraph.style.isBlockQuote { add("paragraphs\(place): block quotes") }
            if paragraph.style.alignment != nil { add("paragraphs\(place): with an alignment") }
            if paragraph.style.startingNumber != nil { add("paragraphs\(place): with a starting number") }
            if paragraph.style.indent > 0 { add("paragraphs\(place): indented") }
            for run in paragraph.runs {
                add("runs\(place)")
                if run.isUnderlined { add("runs\(place): underlined") }
                if run.baselinePosition != .normal { add("runs\(place): superscript or subscript") }
                if run.highlight != nil { add("runs\(place): highlighted") }
                if run.color != nil { add("runs\(place): colored") }
                if run.link != nil {
                    add(run.linkedNoteID == nil ? "runs\(place): links" : "runs\(place): links to notes")
                }
                if run.text.contains("\u{FFFC}"), run.attachment == nil {
                    add("runs\(place): replacement characters without an attachment")
                }
                if let attachment = run.attachment {
                    if run.text != "\u{FFFC}" { add("attachments\(place): runs with other text") }
                    try examine(attachment, in: snapshot, depth: depth)
                }
            }
        }
    }

    private mutating func examine(_ attachment: Note.Attachment, in snapshot: Store.Snapshot, depth: Int) throws {
        let kind = "\(attachment.kind)"
        let place = depth == 0 ? "" : " in table cells"
        add("attachments\(place): \(kind)")
        if attachment.typeIdentifier == nil { add("attachments\(place): without a type") }

        let details: [Any?] = [
            attachment.displayText, attachment.tokenIdentifier, attachment.title, attachment.url,
            attachment.fileName, attachment.summary, attachment.recognizedText, attachment.handwritingText, attachment.table,
        ]
        if details.allSatisfy({ $0 == nil }) { add("attachments\(place): without details, probably without a row") }
        if attachment.recognizedText != nil { add("attachments\(place): with recognized text") }
        if attachment.handwritingText != nil { add("attachments\(place): with handwriting text") }

        switch attachment.kind {
        case .hashtag, .mention, .noteLink, .calculation, .inlineText:
            if attachment.displayText == nil { add("inline attachments\(place): without text") }
            if attachment.kind == .noteLink, attachment.linkedNoteID == nil { add("inline links\(place): without a note identifier") }
        case .table:
            if let table = attachment.table {
                add("tables\(place): decoded")
                if table.rows.isEmpty || table.rows[0].isEmpty { add("tables\(place): decoded without cells") }
                if table.isRightToLeft { add("tables\(place): right to left") }
                if attachment.summary == nil { add("tables\(place): decoded without a summary") }
                for row in table.rows {
                    for cell in row {
                        try examine(cell, in: snapshot, depth: depth + 1)
                    }
                }
            } else if attachment.summary != nil {
                add("tables\(place): not decoded, with a summary")
            } else {
                add("tables\(place): not decoded, without a summary")
            }
        case .webLink:
            if attachment.url == nil { add("link cards\(place): without a URL") }
        default:
            do {
                add(try snapshot.fileURL(for: attachment.id) == nil ? "files: \(kind) not found" : "files: \(kind) found")
            } catch let error as NotesError {
                add("files: \(kind) \(Self.name(of: error))")
            }
        }
    }

    /// The name of an error's case, without the identifier that some cases carry.
    static func name(of error: NotesError) -> String {
        switch error {
        case .folderNotFound: return "folderNotFound"
        case .noteNotFound: return "noteNotFound"
        case .noteLocked: return "noteLocked"
        case .contentNotFound: return "contentNotFound"
        case .unsupportedContent: return "unsupportedContent"
        case .malformedContent: return "malformedContent"
        case .attachmentNotFound: return "attachmentNotFound"
        case .queryFailed: return "queryFailed"
        default: return "\(error)"
        }
    }
}

/// Asks Notes for its count of notes through AppleScript, or returns `nil` if it can't.
func appleScriptNoteCount() -> Int? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "tell application \"Notes\" to count notes"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Int(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

let arguments = CommandLine.arguments.dropFirst()
let root = arguments.first { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Store.defaultRoot
let store = Store(root: root, configuration: try Store.Configuration(timeLimit: .seconds(120)))

/// Prints what the process can and can't read in the Notes folder, without reading any notes.
func diagnose(_ root: URL) {
    let fileManager = FileManager.default
    print("folder exists: \(fileManager.fileExists(atPath: root.path))")
    do {
        _ = try fileManager.contentsOfDirectory(atPath: root.path)
        print("folder can be listed: true")
    } catch {
        let error = error as NSError
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.domain) \($0.code))" } ?? ""
        print("folder can be listed: false, \(error.domain) \(error.code)\(underlying)")
    }
    for name in ["NoteStore.sqlite", "NoteStore.sqlite-wal", "NoteStore.sqlite-shm"] {
        let path = root.appendingPathComponent(name).path
        print(
            "\(name): exists \(fileManager.fileExists(atPath: path)), readable \(fileManager.isReadableFile(atPath: path)), "
                + "writable \(fileManager.isWritableFile(atPath: path))"
        )
    }

    var connection: OpaquePointer?
    defer { sqlite3_close(connection) }
    let path = root.appendingPathComponent("NoteStore.sqlite").path
    let opened = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil)
    print("SQLite open: \(opened), errno \(sqlite3_system_errno(connection))")
    guard opened == SQLITE_OK else { return }
    // The schema table holds table definitions, not notes.
    let read = sqlite3_exec(connection, "SELECT count(*) FROM sqlite_master", nil, nil, nil)
    print(
        "SQLite first read: \(read), extended \(sqlite3_extended_errcode(connection)), "
            + "errno \(sqlite3_system_errno(connection)), \(String(cString: sqlite3_errmsg(connection)))"
    )
}

do {
    try await store.checkAccess()
} catch {
    print("The Notes database can't be read: \(error.localizedDescription)")
    diagnose(root)
    exit(1)
}

let accounts = try await store.accounts()
let folders = try await store.folders()
print("accounts: \(accounts.count)")
print("folders: \(folders.count), of which Recently Deleted: \(folders.filter(\.isRecentlyDeleted).count)")
print("folders without an account: \(folders.filter { $0.account == nil }.count)")
print("notes counted by folders: \(folders.map(\.noteCount).reduce(0, +))")

var tally = Tally()
var cursor: Note.FetchRequest.Cursor?
repeat {
    let request = Note.FetchRequest(includesRecentlyDeleted: true, limit: Note.FetchRequest.maximumLimit, cursor: cursor)
    let (page, next) = try await store.withSnapshot { snapshot in
        let result = try snapshot.search(request)
        var tally = Tally()
        for note in result.notes {
            try tally.examine(note, in: snapshot)
        }
        return (tally, result.nextCursor)
    }
    tally.merge(page)
    cursor = next
} while cursor != nil

for (label, count) in tally.counts.sorted(by: { $0.key < $1.key }) {
    print("\(label): \(count)")
}
let decoded = tally["contents: decoded"]
if decoded > 0 {
    let milliseconds = Double(tally.decodingTime.components.seconds) * 1000 + Double(tally.decodingTime.components.attoseconds) / 1e15
    print(String(format: "average time to read contents: %.2f ms", milliseconds / Double(decoded)))
}

#if DEBUG
    print("")
    print("Stored contents (internal decoders):")
    for (label, count) in try inspectStoredContents(root: root).sorted(by: { $0.key < $1.key }) {
        print("\(label): \(count)")
    }
#endif

if arguments.contains("--applescript") {
    if let count = appleScriptNoteCount() {
        print("notes counted by AppleScript: \(count)")
        print("notes listed outside Recently Deleted: \(tally["notes"] - tally["notes in Recently Deleted"])")
    } else {
        print("notes counted by AppleScript: unavailable")
    }
}
