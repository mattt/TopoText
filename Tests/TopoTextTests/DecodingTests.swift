@testable import TopoText
import Foundation
import Testing

@Suite struct ProtobufTests {
    @Test("A negative int32 reads back as negative")
    func negativeInteger() throws {
        var message = PB()
        message.int(1, -1)
        #expect(message.data.count == 11)
        #expect(try ProtobufMessage(Data(message.data)).integer(1) == -1)
    }

    @Test("A repeated singular field reads its last value")
    func lastValueWins() throws {
        var message = PB()
        message.int(1, 1)
        message.string(2, "first")
        message.int(1, 2)
        message.string(2, "second")
        let decoded = try ProtobufMessage(Data(message.data))
        #expect(decoded.integer(1) == 2)
        #expect(decoded.string(2) == "second")
        #expect(decoded.strings(2) == ["first", "second"])
    }

    @Test("Floats and 64-bit fixed fields decode")
    func fixedFields() throws {
        var message = PB()
        message.float(1, 0.25)
        message.data += [0x11] + Array(repeating: 0xAB, count: 8)  // field 2, fixed64
        let decoded = try ProtobufMessage(Data(message.data))
        #expect(decoded.float(1) == 0.25)
        #expect(decoded.contains(2))
        #expect(decoded.integer(2) == nil)
    }

    @Test(
        "Malformed messages throw",
        arguments: [
            [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01],  // overlong varint
            [0x0A, 0xFF],  // length past the end
            [0x0A],  // missing length
            [0x0B],  // group
            [0x0D, 0x00, 0x00],  // truncated fixed32
        ] as [[UInt8]]
    )
    func malformed(bytes: [UInt8]) {
        #expect(throws: FormatError.malformed) { try ProtobufMessage(Data(bytes)) }
    }

    @Test("A malformed nested message reads as absent")
    func malformedNested() throws {
        var message = PB()
        message.bytes(1, [0x0A, 0xFF])
        let decoded = try ProtobufMessage(Data(message.data))
        #expect(decoded.message(1) == nil)
        #expect(decoded.messages(1).isEmpty)
        #expect(decoded.bytes(1) == [0x0A, 0xFF])
    }
}

@Suite struct GzipTests {
    let payload = noteProtobuf([RunSpec(text: "Raw")])

    @Test("Gzip data with a file name decompresses")
    func fileName() throws {
        let data = gzip(payload)
        #expect(data[3] == 0x08)
        #expect(try data.gunzipped() == Data(payload))
    }

    @Test("Every optional header field is skipped")
    func optionalHeaderFields() throws {
        let plain = gzip(payload)
        let streamStart = plain[10...].firstIndex(of: 0)! + 1
        var data = Data([0x1F, 0x8B, 8, 0x1E, 0, 0, 0, 0, 0, 3])
        data.append(contentsOf: [4, 0, 1, 2, 3, 4])
        data.append(contentsOf: Array("name.pb".utf8) + [0])
        data.append(contentsOf: Array("comment".utf8) + [0])
        data.append(contentsOf: [0xAB, 0xCD])
        data += plain[streamStart...]
        #expect(try NoteDocument(data: data).text == "Raw")
    }

    @Test("A slice of a larger buffer decompresses")
    func slice() throws {
        let data = Data([0xFF, 0xFF]) + gzip(payload)
        #expect(try data[2...].gunzipped() == Data(payload))
    }

    @Test("Data without the gzip signature is unrecognized")
    func unrecognized() {
        #expect(throws: FormatError.unrecognized) { try Data(payload).gunzipped() }
        #expect(throws: FormatError.unrecognized) { try Data("bplist00".utf8).gunzipped() }
        #expect(throws: FormatError.unrecognized) { try Data().gunzipped() }
    }

    @Test(
        "Damaged gzip data is malformed",
        arguments: [
            [0x1F, 0x8B, 8, 0, 0, 0],  // truncated header
            [0x1F, 0x8B, 8, 0x0C, 0, 0, 0, 0, 0, 3, 0xFF, 0xFF, 1, 2, 3, 4, 5, 6, 7, 8],  // FEXTRA past the end
            [0x1F, 0x8B, 9, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0],  // unknown method
            [0x1F, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68],  // FNAME without a terminator
        ] as [[UInt8]]
    )
    func malformed(bytes: [UInt8]) {
        #expect(throws: FormatError.malformed) { try Data(bytes).gunzipped() }
    }

    @Test("A wrong checksum or size in the trailer is malformed")
    func trailer() {
        var data = gzip(payload)
        data[data.count - 8] ^= 0xFF
        #expect(throws: FormatError.malformed) { try data.gunzipped() }

        data = gzip(payload)
        data[data.count - 1] ^= 0xFF
        #expect(throws: FormatError.malformed) { try data.gunzipped() }
    }

    @Test("A truncated deflate stream is malformed")
    func truncatedStream() {
        let data = gzip(Array(repeating: 0x41, count: 4096) + payload)
        #expect(throws: FormatError.malformed) { try (data.prefix(20) + data.suffix(8)).gunzipped() }
    }

    @Test("Note contents without the note path are unrecognized")
    func missingNote() {
        var root = PB()
        root.int(1, 1)
        #expect(throws: FormatError.unrecognized) { try NoteDocument(data: gzip(root.data)) }
        #expect(throws: FormatError.malformed) { try NoteDocument(data: gzip([0x0A, 0xFF])) }
    }
}
