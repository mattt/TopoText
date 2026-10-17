import Foundation

/// A protocol buffer encoder for synthetic fixtures.
struct PB {
    var data: [UInt8] = []

    private mutating func writeVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private mutating func key(_ field: Int, _ wireType: Int) {
        writeVarint(UInt64(field << 3 | wireType))
    }

    /// Writes a varint field, encoding negative values in 10 bytes as `int32` fields are.
    @discardableResult
    mutating func int(_ field: Int, _ value: Int) -> PB {
        key(field, 0)
        writeVarint(UInt64(bitPattern: Int64(value)))
        return self
    }

    @discardableResult
    mutating func float(_ field: Int, _ value: Float) -> PB {
        key(field, 5)
        let bits = value.bitPattern
        data += [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        return self
    }

    @discardableResult
    mutating func bytes(_ field: Int, _ value: [UInt8]) -> PB {
        key(field, 2)
        writeVarint(UInt64(value.count))
        data += value
        return self
    }

    @discardableResult
    mutating func string(_ field: Int, _ value: String) -> PB {
        bytes(field, Array(value.utf8))
    }

    @discardableResult
    mutating func message(_ field: Int, _ value: PB) -> PB {
        bytes(field, value.data)
    }
}

/// Compresses bytes with `/usr/bin/gzip`, which writes the file name in the header (FNAME).
func gzip(_ bytes: [UInt8]) -> Data {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("topotext-gzip-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("in")
    try! Data(bytes).write(to: input)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c", input.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try! process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return output
}
