@testable import TopoText
import Foundation
import SQLite3

// Builders for whole stored documents: the text and runs that `noteMessage(_:)` writes,
// together with the merge state and fields that TopoText does not read.
// Every value is made up.

/// A substring of a document's merge state.
struct SubstringSpec {
    var replica: Int
    var clock: Int
    var length: Int
    /// The style timestamp: a replica and its style clock.
    var style: (replica: Int, clock: Int) = (0, 0)
    var tombstone: Int? = nil
    /// The child indexes, or `nil` for the next substring alone.
    var children: [Int]? = nil
    /// Whether to add a field that no schema names.
    var unknownField = false
}

/// A replica of a document's vector timestamp.
struct ReplicaSpec {
    var uuid: [UInt8]
    var clocks: [Int]
    var subclock: Int? = nil
    var unknownField = false
}

/// A replica UUID of one repeated byte.
func replicaUUID(_ byte: UInt8) -> [UInt8] {
    Array(repeating: byte, count: 16)
}

/// The UUID whose 16 bytes are one repeated byte.
func uuid(_ byte: UInt8) -> UUID {
    UUID(uuid: (byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte))
}

/// The substring that starts every document.
let originSubstring = SubstringSpec(replica: 0, clock: 0, length: 0)
/// The substring that ends every document.
let endSubstring = SubstringSpec(replica: 0, clock: 0xFFFF_FFFF, length: 0, style: (0, 0xFFFF_FFFF), children: [])

/// A run of text and the fields of its `AttributeRun` message, besides the length.
typealias StoredRun = (text: String, attributes: PB)

/// A run of text with attributes that a closure writes.
func run(_ text: String, _ write: (inout PB) -> Void = { _ in }) -> StoredRun {
    var attributes = PB()
    write(&attributes)
    return (text, attributes)
}

/// A `ParagraphStyle` message.
func paragraphStyle(_ type: Int, todo: (uuid: [UInt8], done: Int)? = nil, _ write: (inout PB) -> Void = { _ in }) -> PB {
    var style = PB()
    style.int(1, type)
    if let todo {
        var message = PB()
        message.bytes(1, todo.uuid)
        message.int(2, todo.done)
        style.message(5, message)
    }
    write(&style)
    return style
}

/// An `AttachmentInfo` message.
func attachmentInfo(_ identifier: String, _ type: String) -> PB {
    var info = PB()
    info.string(1, identifier)
    info.string(2, type)
    return info
}

/// Encodes a whole stored document, uncompressed.
/// - Parameters:
///   - runs: The text and its attribute runs.
///   - substrings: The merge state, or `nil` for one substring that replica 1 inserted.
///   - replicas: The vector timestamp, or `nil` for one replica. An empty list writes an empty vector timestamp.
///   - hasVectorTimestamp: Whether to write the vector timestamp.
///   - versions: The number of `Version` messages. The last one holds the note.
///   - minimumSupportedVersion: The `minimumSupportedVersion` of each version, or `nil` to leave the field out.
///   - unknownFields: Whether to add fields that no schema names to the document, the version, and the string.
func storedDocument(
    _ runs: [StoredRun],
    substrings: [SubstringSpec]? = nil,
    replicas: [ReplicaSpec]? = nil,
    hasVectorTimestamp: Bool = true,
    versions: Int = 1,
    minimumSupportedVersion: Int? = 0,
    unknownFields: Bool = false
) -> [UInt8] {
    let text = runs.map(\.text).joined()
    let length = text.utf16.count
    let substrings =
        substrings
        ?? [originSubstring] + (length > 0 ? [SubstringSpec(replica: 1, clock: 0, length: length, style: (1, 0))] : []) + [endSubstring]
    let replicas = replicas ?? (length > 0 ? [ReplicaSpec(uuid: replicaUUID(0x11), clocks: [length, 1])] : [])

    var string = PB()
    string.string(2, text)
    for (index, spec) in substrings.enumerated() {
        func characterID(_ replica: Int, _ clock: Int) -> PB {
            var id = PB()
            id.int(1, replica)
            id.int(2, clock)
            return id
        }
        var substring = PB()
        substring.message(1, characterID(spec.replica, spec.clock))
        substring.int(2, spec.length)
        substring.message(3, characterID(spec.style.replica, spec.style.clock))
        if let tombstone = spec.tombstone { substring.int(4, tombstone) }
        for child in spec.children ?? [index + 1] { substring.int(5, child) }
        if spec.unknownField { substring.string(9, "substring") }
        string.message(3, substring)
    }
    if hasVectorTimestamp {
        var timestamp = PB()
        for spec in replicas {
            var entry = PB()
            entry.bytes(1, spec.uuid)
            for clock in spec.clocks {
                var message = PB()
                message.int(1, clock)
                if let subclock = spec.subclock { message.int(2, subclock) }
                entry.message(2, message)
            }
            if spec.unknownField { entry.string(5, "replica") }
            timestamp.message(1, entry)
        }
        string.message(4, timestamp)
    }
    for run in runs {
        var message = PB()
        message.int(1, run.text.utf16.count)
        message.data += run.attributes.data
        string.message(5, message)
    }
    if unknownFields {
        // `String.attachment` [6], which Apple's schema names and no source has seen, and a field with no name.
        var attachment = PB()
        attachment.string(2, "ATTACHMENT-DATA")
        string.message(6, attachment)
        string.float(100, 1.5)
    }

    var document = PB()
    document.int(1, 0)
    for index in 0 ..< versions {
        var version = PB()
        version.int(1, 0)
        if let minimumSupportedVersion { version.int(2, minimumSupportedVersion) }
        version.message(3, index == versions - 1 ? string : PB())
        if unknownFields { version.int(7, 42) }
        document.message(2, version)
    }
    if unknownFields { document.string(15, "document") }
    return document.data
}

/// The contents of a `ZICNOTEDATA.ZDATA` row for a document: its bytes, gzip-compressed.
func storedData(_ protobuf: [UInt8]) throws -> Data {
    try Data(protobuf).gzipped()
}

/// The text of stored contents, as the reader decodes it.
func storedText(_ data: Data) throws -> String {
    try NoteDocument(data: data).text
}

/// A document with everything that an edit must keep:
/// several replicas, a tombstone, a substring with two children, fields that no schema names,
/// checklist items with identifiers and states, a link on a run,
/// a tag, a mention, a link to a note, a table, and a character of two UTF-16 code units.
enum RichNote {
    static let firstItem = Array(repeating: UInt8(0xA1), count: 16)
    static let secondItem = Array(repeating: UInt8(0xB2), count: 16)
    static let firstReplica = replicaUUID(0x11)
    static let secondReplica = replicaUUID(0x22)
    static let link = "https://example.com/guide"

    static var runs: [StoredRun] {
        [
            run("Trip plan\n") {
                $0.message(2, paragraphStyle(0))
                var font = PB()
                font.string(1, "Helvetica")
                font.float(2, 12)
                $0.message(3, font)
                $0.int(13, 5)
            },
            run("Pack bags\n") {
                $0.message(
                    2,
                    paragraphStyle(103, todo: (firstItem, 1)) {
                        $0.int(3, 0)
                        $0.bytes(9, Array(repeating: 0xC3, count: 16))
                    }
                )
            },
            run("Book hotel\n") {
                $0.message(2, paragraphStyle(103, todo: (secondItem, 0)) { $0.bytes(9, Array(repeating: 0xD4, count: 16)) })
            },
            run("See the "),
            run("guide") {
                $0.int(6, 1)
                $0.string(9, link)
            },
            run(" and "),
            run("\u{FFFC}") { $0.message(12, attachmentInfo("TAG-1", inlineType("hashtag"))) },
            run(" "),
            run("\u{FFFC}") { $0.message(12, attachmentInfo("MENTION-1", inlineType("mention"))) },
            run(" "),
            run("\u{FFFC}") { $0.message(12, attachmentInfo("LINK-1", inlineType("link"))) },
            run("\n"),
            run("\u{FFFC}") { $0.message(12, attachmentInfo("TABLE-1", "com.apple.notes.table")) },
            run("\n"),
            run("Notes 😀 end") {
                $0.int(5, 1)
                $0.int(11, 1)
                $0.int(14, 2)
            },
        ]
    }

    static var text: String { runs.map(\.text).joined() }

    /// The substrings: 69 UTF-16 code units of text from two replicas, around 4 deleted ones.
    static var substrings: [SubstringSpec] {
        [
            originSubstring,
            SubstringSpec(replica: 1, clock: 0, length: 10, style: (1, 0)),
            SubstringSpec(replica: 2, clock: 0, length: 4, style: (2, 9), tombstone: 1, unknownField: true),
            SubstringSpec(replica: 1, clock: 10, length: 21, style: (2, 3), children: [4, 5]),
            SubstringSpec(replica: 2, clock: 4, length: 10, style: (2, 0)),
            SubstringSpec(replica: 1, clock: 31, length: 28, style: (1, 0)),
            endSubstring,
        ]
    }

    static var replicas: [ReplicaSpec] {
        [
            ReplicaSpec(uuid: firstReplica, clocks: [59, 1]),
            ReplicaSpec(uuid: secondReplica, clocks: [14, 10], unknownField: true),
        ]
    }

    static var protobuf: [UInt8] {
        storedDocument(runs, substrings: substrings, replicas: replicas, unknownFields: true)
    }

    static func stored() throws -> StoredNote {
        try StoredNote(protobuf: protobuf)
    }
}

extension StoredNote {
    /// The attributes of each UTF-16 code unit of the text: its run's message, without the length.
    var characterAttributes: [WireMessage] {
        runs.flatMap { run -> [WireMessage] in
            var message = run.message
            message.set(1, nil)
            return Array(repeating: message, count: max(0, run.length))
        }
    }

    /// Every character that the document records, deleted or not, in the order of the substrings.
    var characters: [StoredCharacter] {
        substrings.flatMap { substring -> [StoredCharacter] in
            let id = substring.id
            let replica = id.replica >= 1 && id.replica <= replicas.count ? replicas[id.replica - 1].uuid : []
            return (0 ..< (substring.isEnd ? 0 : substring.length)).map {
                StoredCharacter(replica: replica, clock: id.clock + $0, isDeleted: substring.isTombstone)
            }
        }
    }

    /// Whether every substring can be reached from the first one along the child indexes.
    var isConnected: Bool {
        var reached: Set<Int> = [0]
        for index in substrings.indices where reached.contains(index) {
            reached.formUnion(substrings[index].children)
        }
        return reached.count == substrings.count
    }
}

/// A character of a document's merge state: who inserted it, with what clock value, and whether it is deleted.
struct StoredCharacter: Hashable {
    var replica: [UInt8]
    var clock: Int
    var isDeleted: Bool
}

extension NotesFolder {
    /// The blobs that a query returns from the synthetic database, leaving out NULL values.
    func blobs(_ sql: String) -> [Data] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var blobs: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(statement, 0) {
                blobs.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            }
        }
        return blobs
    }
}

/// A document of the size of a long, much-edited note:
/// most of its substrings hold deleted text, several replicas wrote it, and a few substrings have two children.
/// - Parameters:
///   - units: The length of the text in UTF-16 code units.
///   - substrings: The number of substrings, of which one in five holds text.
func largeDocument(units: Int = 200_000, substrings count: Int = 20_000, replicas replicaCount: Int = 6) -> [UInt8] {
    // The text: paragraphs of 59 letters and a line feed, with a run for every 40 code units. The last paragraph is a checklist item.
    let paragraph = String(repeating: "abcdefghi ", count: 6).dropLast() + "\n"
    let text = String(String(repeating: String(paragraph), count: units / 60).prefix(units - 1))
    let lastStart = (units / 60 - 1) * 60
    var runs: [StoredRun] = []
    var rest = text.prefix(lastStart)
    var index = 0
    while !rest.isEmpty {
        let piece = String(rest.prefix(40))
        rest = rest.dropFirst(40)
        index += 1
        runs.append(
            run(piece) {
                $0.message(2, paragraphStyle(index % 7 == 0 ? 100 : 0) { $0.int(3, 0) })
                if index % 3 == 0 { $0.int(5, 1) }
                $0.int(13, index % 5)
            }
        )
    }
    runs.append(run(String(text.dropFirst(lastStart))) { $0.message(2, paragraphStyle(103, todo: (Array(repeating: 0x77, count: 16), 0))) })

    let visibleCount = count / 5
    let visibleLength = units / visibleCount
    var clocks = Array(repeating: 0, count: replicaCount)
    var specs = [originSubstring]
    var remaining = text.utf16.count
    for position in 0 ..< count {
        let replica = position % replicaCount
        let isVisible = position % 5 == 0 && remaining > 0
        let length = isVisible ? (position / 5 == visibleCount - 1 ? remaining : min(remaining, visibleLength)) : 1 + position % 30
        if isVisible { remaining -= length }
        var spec = SubstringSpec(replica: replica + 1, clock: clocks[replica], length: length, style: (replica + 1, position % 50))
        spec.tombstone = isVisible ? nil : 1
        // A few substrings have two children, as after concurrent insertions.
        if position % 4_000 == 7 { spec.children = [position + 2, position + 3] }
        clocks[replica] += length
        specs.append(spec)
    }
    if remaining > 0 {
        specs.append(SubstringSpec(replica: 1, clock: clocks[0], length: remaining, style: (1, 0)))
        clocks[0] += remaining
    }
    specs.append(endSubstring)
    let replicas = clocks.enumerated().map { ReplicaSpec(uuid: replicaUUID(UInt8(0x10 + $0.offset)), clocks: [$0.element, 60]) }
    return storedDocument(runs, substrings: specs, replicas: replicas)
}
