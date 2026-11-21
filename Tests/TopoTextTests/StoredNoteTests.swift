@testable import TopoText
import Foundation
import Testing

@Suite struct WireMessageTests {
    @Test("A message that was not changed encodes to its bytes, whatever form they have")
    func nonCanonicalBytes() throws {
        // A key, a varint, and a length, each one byte longer than it needs to be, then fixed fields.
        let bytes: [UInt8] =
            [0x88, 0x00, 0x81, 0x00] + [0x12, 0x82, 0x00, 0x41, 0x42] + [0x1D, 1, 2, 3, 4] + [0x21, 1, 2, 3, 4, 5, 6, 7, 8]
        let message = try WireMessage(bytes)
        #expect(message.fields.map(\.number) == [1, 2, 3, 4])
        #expect(message.varint(1) == 1)
        #expect(message.bytes(2) == [0x41, 0x42])
        #expect(message.encoded() == bytes)
        #expect(message.reencoded(as: .init()) == [0x08, 0x01, 0x12, 0x02, 0x41, 0x42, 0x1D, 1, 2, 3, 4, 0x21, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("Setting a field to the value that it has keeps its bytes, and another value rewrites that field alone")
    func setField() throws {
        var message = try WireMessage([0x08, 0x81, 0x00, 0x10, 0x05] as [UInt8])
        message.set(1, .varint(1))
        message.setVarint(3, 0)
        #expect(message.encoded() == [0x08, 0x81, 0x00, 0x10, 0x05])
        message.set(2, .varint(6))
        #expect(message.encoded() == [0x08, 0x81, 0x00, 0x10, 0x06])
    }

    @Test("A new field goes in field order, and a repeated field keeps its place")
    func order() throws {
        var source = PB()
        source.int(1, 1)
        source.int(3, 3)
        source.int(5, 5)
        source.int(3, 4)
        var message = try WireMessage(source.data)
        message.set(2, .varint(2))
        message.set(9, .varint(9))
        #expect(message.fields.map(\.number) == [1, 2, 3, 5, 3, 9])
        message.setRepeated(3, [.varint(4), .varint(7), .varint(3)])
        #expect(message.fields.map(\.number) == [1, 2, 3, 3, 3, 5, 9])
        #expect(message.values(3) == [.varint(4), .varint(7), .varint(3)])
        message.set(5, nil)
        #expect(!message.contains(5))
    }

    @Test(
        "Malformed messages throw",
        arguments: [[0x0A, 0xFF], [0x0A], [0x0B], [0x0D, 0x00, 0x00], [0x08]] as [[UInt8]]
    )
    func malformed(bytes: [UInt8]) {
        #expect(throws: FormatError.malformed) { try WireMessage(bytes) }
    }
}

@Suite struct GzipEncodingTests {
    @Test(
        "Compressed data decompresses to the same bytes",
        arguments: [[], [0x00], Array("Hello, hello, hello".utf8), (0 ..< 70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }] as [[UInt8]]
    )
    func roundTrip(bytes: [UInt8]) throws {
        let compressed = try Data(bytes).gzipped()
        #expect(Array(compressed.prefix(4)) == [0x1F, 0x8B, 8, 0])
        #expect(try compressed.gunzipped() == Data(bytes))
    }

    @Test("The system's gunzip reads the compressed data")
    func systemGunzip() throws {
        let payload = Data(RichNote.protobuf)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(try payload.gzipped())
        input.fileHandleForWriting.closeFile()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(result == payload)
    }
}

@Suite struct StoredNoteTests {
    /// Checks that a document decodes and encodes without loss, by both ways of encoding.
    private func expectLossless(_ protobuf: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let stored = try StoredNote(protobuf: protobuf)
        #expect(stored.protobuf() == protobuf, sourceLocation: sourceLocation)
        #expect(try stored.data().gunzipped() == Data(protobuf), sourceLocation: sourceLocation)
        // The fixtures are written in the canonical form, so encoding every level again gives the same bytes too.
        #expect(try WireMessage(protobuf).reencoded(as: StoredNote.schema) == protobuf, sourceLocation: sourceLocation)
        // The reader sees the same text and runs in the encoded document.
        let reader = try NoteDocument(data: try stored.data())
        #expect(reader.text == stored.text, sourceLocation: sourceLocation)
        #expect(reader.runs.map(\.length) == stored.runs.map(\.length), sourceLocation: sourceLocation)
        #expect(reader.paragraphs.count == stored.paragraphRanges.count, sourceLocation: sourceLocation)
    }

    @Test("Every note and table of the synthetic databases encodes to its stored bytes")
    func databaseFixtures() throws {
        var notes = 0
        var tables = 0
        for folder in [try NotesFolder.current(), try NotesFolder.older()] {
            for data in folder.blobs("SELECT ZDATA FROM ZICNOTEDATA") {
                // Some rows hold other formats, which are not note documents.
                guard let protobuf = try? data.gunzipped(), (try? NoteDocument(data: data)) != nil else { continue }
                try expectLossless(Array(protobuf))
                notes += 1
            }
            let tableColumns = ["ZMERGEABLEDATA1", "ZMERGEABLEDATA"]
            for data in tableColumns.flatMap({ folder.blobs("SELECT \($0) FROM ZICCLOUDSYNCINGOBJECT") }) {
                // A table is another kind of document in the same wrapper. Its bytes are kept, and its cells are not edited.
                // One fixture is damaged on purpose, and doesn't decompress.
                guard let protobuf = (try? data.gunzipped()).map(Array.init) else { continue }
                #expect(try WireMessage(protobuf).encoded() == protobuf)
                #expect(try Data(protobuf).gzipped().gunzipped() == Data(protobuf))
                tables += 1
            }
        }
        #expect(notes == 7)
        #expect(tables == 3)
    }

    @Test("Documents of every kind of run encode to their bytes")
    func runFixtures() throws {
        let runs: [[RunSpec]] = [
            [],
            [RunSpec(text: "Plain")],
            [RunSpec(text: "Title\n", style: 0), RunSpec(text: "Bold", weight: 1), RunSpec(text: " link", link: "https://example.com")],
            [RunSpec(text: "One\n", style: 102, start: 3), RunSpec(text: "Two\n", style: 103, checked: true), RunSpec(text: "Quote", quote: true)],
            [RunSpec(text: "Color", color: (1, 0.5, 0.25, 1), highlight: 3), RunSpec(text: "x", superscript: -1), RunSpec(text: "😀")],
            [RunSpec(text: "\u{FFFC}", attachment: ("TAG-1", inlineType("hashtag"))), RunSpec(text: "\n\u{FFFC}", attachment: ("T", "com.apple.notes.table"))],
            [RunSpec(text: "Right", indent: 2, alignment: 2, strike: true, underline: true)],
        ]
        for runs in runs {
            try expectLossless(noteProtobuf(runs))
        }
    }

    @Test("A document with merge state and fields that no schema names encodes to its bytes")
    func richFixture() throws {
        try expectLossless(RichNote.protobuf)
        try expectLossless(storedDocument([]))
        try expectLossless(storedDocument([run("Plain")], hasVectorTimestamp: false))
        try expectLossless(storedDocument([run("Two versions")], versions: 2, unknownFields: true))
    }

    @Test("The merge state decodes")
    func mergeState() throws {
        let stored = try RichNote.stored()
        #expect(stored.text == RichNote.text)
        #expect(stored.length == 69)
        #expect(stored.brokenInvariants.isEmpty)

        #expect(stored.substrings.count == 7)
        #expect(stored.substrings.map(\.length) == [0, 10, 4, 21, 10, 28, 0])
        #expect(stored.substrings.map(\.id.replica) == [0, 1, 2, 1, 2, 1, 0])
        #expect(stored.substrings.map(\.id.clock) == [0, 0, 0, 10, 4, 31, 0xFFFF_FFFF])
        #expect(stored.substrings.map(\.isTombstone) == [false, false, true, false, false, false, false])
        #expect(stored.substrings.map(\.children) == [[1], [2], [3], [4, 5], [5], [6], []])
        #expect(stored.substrings[2].styleTimestamp == .init(replica: 2, clock: 9))
        #expect(stored.substrings.last?.isEnd == true)
        #expect(stored.isConnected)

        #expect(stored.replicas.map(\.uuid) == [RichNote.firstReplica, RichNote.secondReplica])
        #expect(stored.replicas.map(\.textClock) == [59, 14])
        #expect(stored.replicas.map(\.styleClock) == [1, 10])

        #expect(stored.runs.count == 15)
        #expect(stored.runs[1].styleType == 103)
        #expect(stored.runs[1].todo?.bytes(1) == RichNote.firstItem)
        #expect(stored.runs[1].todo?.varint(2) == 1)
        #expect(stored.runs[12].attachmentType == "com.apple.notes.table")
        #expect(stored.runs.filter(\.hasAttachment).count == 4)
    }

    @Test("Paragraphs follow the line feeds, as the reader counts them")
    func paragraphs() throws {
        let stored = try StoredNote(protobuf: storedDocument([run("One\n\nThree 😀\n")]))
        #expect(stored.paragraphRanges.map(\.content) == [0 ..< 3, 4 ..< 4, 5 ..< 13])
        #expect(stored.paragraphRanges.map(\.full) == [0 ..< 4, 4 ..< 5, 5 ..< 14])
        #expect(try RichNote.stored().paragraphRanges.count == 6)
        #expect(try RichNote.stored().paragraphRanges.last?.hasLineFeed == false)
    }

    @Test("A packed list of children decodes, and is written back packed")
    func packedChildren() throws {
        var message = PB()
        message.int(2, 3)
        message.bytes(5, [0x02, 0xAC, 0x02])
        var substring = StoredNote.Substring(try WireMessage(message.data))
        #expect(substring.children == [2, 300])
        substring.children = [3, 301]
        #expect(substring.message.bytes(5) == [0x03, 0xAD, 0x02])
    }

    @Test("Data that is not a note document does not decode")
    func notADocument() throws {
        #expect(throws: FormatError.unrecognized) { try StoredNote(data: Data("bplist00".utf8)) }
        #expect(throws: FormatError.unrecognized) { try StoredNote(protobuf: [0x08, 0x01]) }
        #expect(throws: FormatError.malformed) { try StoredNote(protobuf: [0x0A, 0xFF]) }
        // A substring that is not a message.
        var string = PB()
        string.string(2, "x")
        string.bytes(3, [0x0A, 0xFF])
        var version = PB()
        version.message(3, string)
        var document = PB()
        document.message(2, version)
        #expect(throws: FormatError.malformed) { try StoredNote(protobuf: document.data) }
    }

    @Test("Each invariant that an edit relies on is checked")
    func invariants() throws {
        func broken(_ protobuf: [UInt8]) throws -> [StoredNote.Invariant] {
            try StoredNote(protobuf: protobuf).brokenInvariants
        }
        let text = [run("Hello")]
        let replica = ReplicaSpec(uuid: replicaUUID(0x11), clocks: [5, 1])
        func substrings(_ middle: SubstringSpec) -> [SubstringSpec] { [originSubstring, middle, endSubstring] }
        let middle = SubstringSpec(replica: 1, clock: 0, length: 5, style: (1, 0))

        #expect(try broken(storedDocument(text)).isEmpty)
        #expect(try broken(storedDocument(text, versions: 2)) == [.oneVersion])
        #expect(try broken(storedDocument(text, hasVectorTimestamp: false)).contains(.vectorTimestamp))
        #expect(try broken(noteProtobuf([RunSpec(text: "Hello")])).contains(.vectorTimestamp))
        #expect(try broken(storedDocument(text, replicas: [ReplicaSpec(uuid: [1, 2, 3], clocks: [5, 1])])) == [.replicaIdentifiers])
        #expect(try broken(storedDocument(text, replicas: [ReplicaSpec(uuid: replicaUUID(0x11), clocks: [5, 1], subclock: 2)])) == [.noSubclock])
        #expect(try broken(storedDocument(text, substrings: [originSubstring, middle], replicas: [replica])).contains(.endSubstring))
        #expect(try broken(storedDocument(text, substrings: [originSubstring, endSubstring, middle, endSubstring])).contains(.endSubstring))
        #expect(try broken(storedDocument(text, substrings: substrings(SubstringSpec(replica: 1, clock: 0, length: 4)))) == [.substringLengths])
        #expect(try broken(storedDocument(text, substrings: substrings(SubstringSpec(replica: 2, clock: 0, length: 5)))) == [.replicaIndexes])
        #expect(try broken(storedDocument(text, substrings: substrings(SubstringSpec(replica: 1, clock: 0, length: 5, style: (3, 0))))) == [.replicaIndexes])
        #expect(try broken(storedDocument(text, substrings: substrings(SubstringSpec(replica: 1, clock: 1, length: 5)))) == [.textClocks])
        #expect(try broken(storedDocument(text, substrings: substrings(SubstringSpec(replica: 1, clock: 0, length: 5, style: (1, 1 << 31))))) == [.clockRange])
        for children in [[], [1], [3]] {
            let document = storedDocument(text, substrings: substrings(SubstringSpec(replica: 1, clock: 0, length: 5, children: children)))
            // Without a child that comes later, the end marker can't be reached either.
            #expect(try broken(document) == [.childIndexes, .reachableSubstrings])
        }
        #expect(try broken(storedDocument(text, minimumSupportedVersion: 2)) == [.supportedVersion])
        #expect(try broken(storedDocument(text, minimumSupportedVersion: nil)).isEmpty)
        #expect(try broken(storedDocument(text, substrings: [middle, endSubstring])).contains(.originSubstring))

        // A tombstone value other than 1.
        var deleted = SubstringSpec(replica: 1, clock: 5, length: 1, tombstone: 2)
        deleted.children = [3]
        let withDeleted = [originSubstring, middle, deleted, endSubstring]
        #expect(
            try broken(storedDocument(text, substrings: withDeleted, replicas: [ReplicaSpec(uuid: replicaUUID(0x11), clocks: [6, 1])])) == [.tombstoneValues]
        )

        // Runs that end before the text, and a run with a negative length.
        var short = try StoredNote(protobuf: storedDocument(text))
        short.runs[0].length = 4
        #expect(short.brokenInvariants == [.runLengths])
        short.runs = [.init(try WireMessage([0x08] + Array(repeating: 0xFF, count: 9) + [0x01])), .init(length: 6)]
        #expect(short.runs[0].length == -1)
        #expect(short.brokenInvariants == [.runLengths])

        // Text that is not valid UTF-8.
        var invalid = storedDocument([run("Hell\u{7F}")])
        let index = try #require(invalid.firstIndex(of: 0x7F))
        invalid[index] = 0xFF
        #expect(try broken(invalid).contains(.validText))
        #expect(try StoredNote(protobuf: invalid).protobuf() == invalid)
    }
}
