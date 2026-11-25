import Foundation

/// A protocol buffer message that encodes back to the bytes it was decoded from.
///
/// ``ProtobufMessage`` reads values and drops how they were written.
/// This type keeps every field in its order, known or not,
/// together with the bytes of its key and length as they were stored,
/// so a message that was not changed encodes to the same bytes.
/// A field that is set or added is written in the canonical form.
struct WireMessage: Hashable, Sendable {
    /// The value of a field, by wire type.
    enum Value: Hashable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    struct Field: Hashable, Sendable {
        let number: Int
        let value: Value
        /// The stored bytes that the value does not determine:
        /// the key, then the varint of a varint field or the length of a length-delimited field.
        /// It is `nil` for a field whose stored bytes had the canonical form, and for a field that was not decoded:
        /// both are written in the canonical form, which for the first gives the stored bytes.
        fileprivate let prefix: [UInt8]?

        init(_ number: Int, _ value: Value) {
            self.number = number
            self.value = value
            prefix = nil
        }

        fileprivate init(number: Int, value: Value, prefix: [UInt8]) {
            self.number = number
            self.value = value
            self.prefix = prefix
        }
    }

    /// The names of the fields that hold messages, for ``reencoded(as:)``.
    struct Schema: Sendable {
        var nested: [Int: Schema] = [:]
    }

    var fields: [Field]

    init(_ fields: [Field] = []) {
        self.fields = fields
    }

    /// Decodes a message.
    /// - Throws: ``FormatError/malformed`` if the bytes are not a protocol buffer message.
    init(_ bytes: some Collection<UInt8>) throws {
        let bytes = Array(bytes)
        var fields: [Field] = []
        try Self.scan(bytes, in: 0 ..< bytes.count) { number, scanned, field, isCanonical in
            let value: Value
            // The end of the key and of the varint or length, which is where the other values start.
            var prefixEnd = field.upperBound
            switch scanned {
            case .varint(let varint):
                value = .varint(varint)
            case .fixed64(let fixed):
                value = .fixed64(fixed)
                prefixEnd -= 8
            case .bytes(let range):
                value = .bytes(Array(bytes[range]))
                prefixEnd = range.lowerBound
            case .fixed32(let fixed):
                value = .fixed32(fixed)
                prefixEnd -= 4
            }
            if isCanonical {
                fields.append(Field(number, value))
            } else {
                fields.append(Field(number: number, value: value, prefix: Array(bytes[field.lowerBound ..< prefixEnd])))
            }
        }
        self.fields = fields
    }

    /// The value of a field in the bytes of a message, by wire type.
    enum Scanned {
        case varint(UInt64)
        case fixed64(UInt64)
        /// The range of the bytes of a length-delimited field.
        case bytes(Range<Int>)
        case fixed32(UInt32)
    }

    /// Reads the fields of a message in place, without a copy of any value.
    ///
    /// A document holds tens of thousands of small messages, and this reads one of them without an allocation.
    /// - Parameters:
    ///   - bytes: The bytes that hold the message.
    ///   - range: The range of the message in the bytes.
    ///   - visit: A closure that takes each field in order: its number, its value, the range of its bytes,
    ///     and whether its key and its varint or length have the canonical form.
    /// - Throws: ``FormatError/malformed`` if the bytes are not a protocol buffer message.
    static func scan(
        _ bytes: [UInt8],
        in range: Range<Int>,
        _ visit: (_ number: Int, _ value: Scanned, _ field: Range<Int>, _ isCanonical: Bool) -> Void
    ) throws {
        var index = range.lowerBound
        let end = range.upperBound
        // Whether each varint of the current field has the shortest form, which is the form that is written.
        var isCanonical = true

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            let start = index
            while index < end, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    // A shorter form exists if the last byte adds no bits. The tenth byte has room for one bit only.
                    let count = index - start
                    if (byte == 0 && count > 1) || (count == 10 && byte > 1) { isCanonical = false }
                    return result
                }
                shift += 7
            }
            throw FormatError.malformed
        }

        func readFixed(_ count: Int) throws -> UInt64 {
            guard end - index >= count else {
                throw FormatError.malformed
            }
            defer { index += count }
            return bytes[index ..< index + count].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        while index < end {
            let start = index
            isCanonical = true
            let key = try readVarint()
            let number = Int(truncatingIfNeeded: key >> 3)
            let value: Scanned
            switch key & 0x7 {
            case 0:
                value = .varint(try readVarint())
            case 1:
                value = .fixed64(try readFixed(8))
            case 2:
                let length = try readVarint()
                guard length <= UInt64(end - index) else {
                    throw FormatError.malformed
                }
                value = .bytes(index ..< index + Int(length))
                index += Int(length)
            case 5:
                value = .fixed32(UInt32(truncatingIfNeeded: try readFixed(4)))
            default:
                // Groups (wire types 3 and 4) are deprecated and absent from these formats.
                throw FormatError.malformed
            }
            visit(number, value, start ..< index, isCanonical)
        }
    }

    /// The bytes of the message.
    ///
    /// Each decoded field is written as it was stored, so a message that was not changed
    /// encodes to the bytes it was decoded from.
    func encoded() -> [UInt8] {
        var output: [UInt8] = []
        for field in fields {
            Self.write(field, prefix: field.prefix, to: &output)
        }
        return output
    }

    /// The bytes of the message, with every key, varint, and length written in the canonical form,
    /// and the same done for the nested messages that the schema names.
    ///
    /// The result equals ``encoded()`` only if the stored bytes were canonical at each of those levels,
    /// which shows that a field written by an edit has the same form as the fields around it.
    func reencoded(as schema: Schema) -> [UInt8] {
        var output: [UInt8] = []
        for field in fields {
            var field = Field(field.number, field.value)
            if case .bytes(let bytes) = field.value, let nested = schema.nested[field.number], let message = try? WireMessage(bytes) {
                field = Field(field.number, .bytes(message.reencoded(as: nested)))
            }
            Self.write(field, prefix: nil, to: &output)
        }
        return output
    }

    /// Appends a varint in the canonical form.
    static func appendVarint(_ value: UInt64, to output: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            output.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        output.append(UInt8(value))
    }

    private static func write(_ field: Field, prefix: [UInt8]?, to output: inout [UInt8]) {
        func writeVarint(_ value: UInt64) {
            appendVarint(value, to: &output)
        }
        func writeFixed(_ value: UInt64, _ count: Int) {
            for index in 0 ..< count {
                output.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))))
            }
        }
        func writeKey(_ wireType: UInt64) {
            writeVarint(UInt64(truncatingIfNeeded: field.number) << 3 | wireType)
        }

        switch field.value {
        case .varint(let value):
            if let prefix {
                output += prefix
            } else {
                writeKey(0)
                writeVarint(value)
            }
        case .fixed64(let value):
            if let prefix { output += prefix } else { writeKey(1) }
            writeFixed(value, 8)
        case .bytes(let bytes):
            if let prefix {
                output += prefix
            } else {
                writeKey(2)
                writeVarint(UInt64(bytes.count))
            }
            output += bytes
        case .fixed32(let value):
            if let prefix { output += prefix } else { writeKey(5) }
            writeFixed(UInt64(value), 4)
        }
    }
}

// MARK: - Reading

extension WireMessage {
    /// Returns whether the message has a field with the number.
    func contains(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }

    /// The values of the fields with the number, in order.
    func values(_ number: Int) -> [Value] {
        fields.compactMap { $0.number == number ? $0.value : nil }
    }

    /// The value of a varint field. Where the field repeats, this is its last value.
    func varint(_ number: Int) -> UInt64? {
        for field in fields.reversed() where field.number == number {
            if case .varint(let value) = field.value {
                return value
            }
        }
        return nil
    }

    /// The value of a `uint32` field, which keeps the low 32 bits of the varint.
    func uint32(_ number: Int) -> Int? {
        varint(number).map { Int($0 & 0xFFFF_FFFF) }
    }

    /// The value of an `int32` field, which keeps the low 32 bits of the varint with their sign.
    func int32(_ number: Int) -> Int? {
        varint(number).map { Int(Int32(truncatingIfNeeded: $0)) }
    }

    /// The value of a length-delimited field. Where the field repeats, this is its last value.
    func bytes(_ number: Int) -> [UInt8]? {
        for field in fields.reversed() where field.number == number {
            if case .bytes(let bytes) = field.value {
                return bytes
            }
        }
        return nil
    }

    func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The message in a length-delimited field, or `nil` if the field is absent or doesn't hold a message.
    func message(_ number: Int) -> WireMessage? {
        bytes(number).flatMap { try? WireMessage($0) }
    }
}

// MARK: - Changing

extension WireMessage {
    /// Sets the value of a field, or removes the field when the value is `nil`.
    ///
    /// A field that already has the value keeps its stored bytes.
    /// A field that the message lacks goes before the first field with a higher number,
    /// which keeps a message that was in field order in that order.
    mutating func set(_ number: Int, _ value: Value?) {
        guard let value else {
            fields.removeAll { $0.number == number }
            return
        }
        if let index = fields.lastIndex(where: { $0.number == number }) {
            if fields[index].value != value {
                fields[index] = Field(number, value)
            }
        } else {
            fields.insert(Field(number, value), at: insertionIndex(for: number))
        }
    }

    /// Sets a varint field, unless the field reads as the value already.
    ///
    /// An absent field reads as zero, so this leaves an absent field absent when the value is zero.
    mutating func setVarint(_ number: Int, _ value: UInt64) {
        if (varint(number) ?? 0) != value {
            set(number, .varint(value))
        }
    }

    /// Sets a field to a message, unless the field holds the same bytes already.
    mutating func setMessage(_ number: Int, _ message: WireMessage) {
        set(number, .bytes(message.encoded()))
    }

    /// Replaces the values of a repeated field.
    ///
    /// Each value that the field already holds keeps its stored bytes.
    /// The values go where the field's first value was,
    /// or before the first field with a higher number if the message lacks the field.
    mutating func setRepeated(_ number: Int, _ values: [Value]) {
        let indexes = fields.indices.filter { fields[$0].number == number }
        // Most changes leave most values in place, so match the values at both ends first.
        var head = 0
        while head < indexes.count, head < values.count, fields[indexes[head]].value == values[head] {
            head += 1
        }
        guard head < indexes.count || head < values.count else { return }
        var tail = 0
        while tail < indexes.count - head, tail < values.count - head, fields[indexes[indexes.count - 1 - tail]].value == values[values.count - 1 - tail] {
            tail += 1
        }
        let old = indexes[head ..< indexes.count - tail].map { fields[$0] }
        let new = values[head ..< values.count - tail]
        if old.count == new.count {
            // The same number of values: each one takes the place of the value that it replaces.
            for (index, value) in zip(indexes[head ..< indexes.count - tail], new) where fields[index].value != value {
                fields[index] = Field(number, value)
            }
            return
        }
        var stored: [Value: [Field]] = [:]
        for field in old.reversed() {
            stored[field.value, default: []].append(field)
        }
        let replacement =
            indexes.prefix(head).map { fields[$0] } + new.map { stored[$0]?.popLast() ?? Field(number, $0) } + indexes.suffix(tail).map { fields[$0] }
        fields.removeAll { $0.number == number }
        fields.insert(contentsOf: replacement, at: indexes.first ?? insertionIndex(for: number))
    }

    private func insertionIndex(for number: Int) -> Int {
        fields.firstIndex { $0.number > number } ?? fields.count
    }
}
