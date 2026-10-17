import Foundation

/// A protocol buffer message, decoded without a schema.
///
/// Fields keep their wire values; the accessors interpret them
/// by the types that the Notes formats use.
/// Where a field repeats, the singular accessors return its last value,
/// as protocol buffers specify.
/// Nested messages are decoded when an accessor reads them.
struct ProtobufMessage {
    private enum WireValue {
        case varint(UInt64)
        case fixed64(UInt64)
        case lengthDelimited(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    private var fields: [(number: Int, value: WireValue)] = []

    init(_ data: Data) throws {
        try self.init(ArraySlice(data))
    }

    init(_ bytes: ArraySlice<UInt8>) throws {
        var index = bytes.startIndex

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.endIndex, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    return result
                }
                shift += 7
            }
            throw FormatError.malformed
        }

        func readFixed(_ count: Int) throws -> UInt64 {
            guard bytes.endIndex - index >= count else {
                throw FormatError.malformed
            }
            defer { index += count }
            return bytes[index ..< index + count].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        while index < bytes.endIndex {
            let key = try readVarint()
            let number = Int(truncatingIfNeeded: key >> 3)
            switch key & 0x7 {
            case 0:
                fields.append((number, .varint(try readVarint())))
            case 1:
                fields.append((number, .fixed64(try readFixed(8))))
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.endIndex - index) else {
                    throw FormatError.malformed
                }
                let end = index + Int(length)
                fields.append((number, .lengthDelimited(bytes[index ..< end])))
                index = end
            case 5:
                fields.append((number, .fixed32(UInt32(truncatingIfNeeded: try readFixed(4)))))
            default:
                // Groups (wire types 3 and 4) are deprecated and absent from these formats.
                throw FormatError.malformed
            }
        }
    }

    /// The numbers of the message's fields, in order, with repeats.
    var fieldNumbers: [Int] {
        fields.map(\.number)
    }

    /// Returns whether the message has a field with the number.
    func contains(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }

    /// The value of a varint field, read as a signed 64-bit integer,
    /// which also covers negative `int32` values.
    func integer(_ number: Int) -> Int? {
        for field in fields.reversed() where field.number == number {
            if case .varint(let value) = field.value {
                return Int(Int64(bitPattern: value))
            }
        }
        return nil
    }

    /// The value of an `int32` field.
    ///
    /// As protocol buffers specify, the value keeps the low 32 bits of the varint,
    /// so a damaged field can't hold a value outside the range of `Int32`.
    func int32(_ number: Int) -> Int? {
        integer(number).map { Int(Int32(truncatingIfNeeded: $0)) }
    }

    /// The value of a `float` field.
    func float(_ number: Int) -> Float? {
        for field in fields.reversed() where field.number == number {
            if case .fixed32(let value) = field.value {
                return Float(bitPattern: value)
            }
        }
        return nil
    }

    func bytes(_ number: Int) -> ArraySlice<UInt8>? {
        for field in fields.reversed() where field.number == number {
            if case .lengthDelimited(let bytes) = field.value {
                return bytes
            }
        }
        return nil
    }

    func allBytes(_ number: Int) -> [ArraySlice<UInt8>] {
        fields.compactMap { field in
            guard field.number == number, case .lengthDelimited(let bytes) = field.value else { return nil }
            return bytes
        }
    }

    func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    func strings(_ number: Int) -> [String] {
        allBytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    func message(_ number: Int) -> ProtobufMessage? {
        bytes(number).flatMap { try? ProtobufMessage($0) }
    }

    /// The messages of a repeated field, leaving out any that are malformed.
    func messages(_ number: Int) -> [ProtobufMessage] {
        allBytes(number).compactMap { try? ProtobufMessage($0) }
    }
}

/// A problem with the format of stored note contents or tables.
enum FormatError: Error, Hashable {
    /// The data is not in a format that TopoText reads, such as a property list.
    case unrecognized
    /// The data starts like a format that TopoText reads, but is damaged or truncated.
    case malformed
}
