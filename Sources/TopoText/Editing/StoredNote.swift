import Foundation

/// The stored document of one note, with every field that Notes wrote.
///
/// ``NoteDocument`` reads the text and the attribute runs, and drops the rest.
/// This type keeps the whole document, so that an edit can change part of it
/// and write the rest back as it was.
/// The structure, with field numbers in brackets (see <doc:NoteStore>):
///
/// - `Document`: `serializationVersion` [1], repeated `Version` [2]
/// - `Version`: `serializationVersion` [1], `minimumSupportedVersion` [2], `data` [3]
/// - `String` (the `data`): `string` [2], repeated `Substring` [3], `VectorTimestamp` [4],
///   repeated `AttributeRun` [5], repeated `Attachment` [6]
/// - `Substring`: `charID` [1], `length` [2], `timestamp` [3], `tombstone` [4], repeated `child` [5]
/// - `CharID`: `replicaID` [1], `clock` [2]
/// - `VectorTimestamp`: repeated `Clock` [1]
/// - `Clock`: `replicaUUID` [1], repeated `ReplicaClock` [2]
/// - `ReplicaClock`: `clock` [1], `subclock` [2]
///
/// The substrings, the vector timestamp, and the style timestamps are the merge state:
/// what Notes uses to combine the edits of several devices.
///
/// Encoding a document that was not changed gives the bytes that it was decoded from.
struct StoredNote: Hashable, Sendable {
    /// The identifier of a character: the replica that inserted it, and that replica's clock at the time.
    ///
    /// A style timestamp has the same form, with the replica's style clock.
    struct CharacterID: Hashable, Sendable {
        /// A 1-based index into the replicas, or 0 for the origin and the end marker.
        var replica: Int
        var clock: Int

        fileprivate init(_ message: WireMessage?) {
            replica = message?.uint32(1) ?? 0
            clock = message?.uint32(2) ?? 0
        }

        /// Reads the identifier from a `CharID` message in the bytes of a substring, in place.
        ///
        /// It gives the values that ``init(_:)`` gives for the decoded message, and zeros for bytes that don't decode.
        fileprivate init(_ bytes: [UInt8], in range: Range<Int>) {
            var replica = 0
            var clock = 0
            do {
                try WireMessage.scan(bytes, in: range) { number, value, _, _ in
                    guard case .varint(let value) = value else { return }
                    if number == 1 { replica = Int(value & 0xFFFF_FFFF) }
                    if number == 2 { clock = Int(value & 0xFFFF_FFFF) }
                }
                self.init(replica: replica, clock: clock)
            } catch {
                self.init(replica: 0, clock: 0)
            }
        }

        init(replica: Int, clock: Int) {
            self.replica = replica
            self.clock = clock
        }

        /// A message with both fields written, as Notes writes them, zero or not.
        fileprivate var message: WireMessage {
            WireMessage([.init(1, .varint(UInt64(replica))), .init(2, .varint(UInt64(clock)))])
        }

        /// Writes the identifier to a field of a message, and leaves the field alone if it reads as the identifier already.
        fileprivate func write(to message: inout WireMessage, field: Int) {
            guard CharacterID(message.message(field)) != self else { return }
            var nested = message.message(field) ?? WireMessage()
            nested.setVarint(1, UInt64(replica))
            nested.setVarint(2, UInt64(clock))
            message.setMessage(field, nested)
        }
    }

    /// A run of characters that one replica inserted together, with consecutive clock values.
    ///
    /// The substrings are in the order of the text.
    /// A substring with a tombstone holds deleted characters, which are not in the text.
    struct Substring: Hashable, Sendable {
        /// The clock value of the substring that ends every document.
        static let endClock = 0xFFFF_FFFF

        /// The bytes of the stored message.
        ///
        /// The properties below hold its values, read once in place, and write each change back to the bytes.
        /// A substring that an edit does not change keeps the bytes that it was decoded from.
        private(set) var encoded: [UInt8]

        /// Decodes a `Substring` message.
        /// - Throws: ``FormatError/malformed`` if the bytes are not a protocol buffer message.
        init(encoded: [UInt8]) throws {
            self.encoded = encoded
            // One pass over the fields. Where a field repeats, its last value counts, as in ``WireMessage``.
            var id = CharacterID(replica: 0, clock: 0)
            var length = 0
            var styleTimestamp = CharacterID(replica: 0, clock: 0)
            var tombstoneValue: UInt64 = 0
            var children: [Int] = []
            try WireMessage.scan(encoded, in: 0 ..< encoded.count) { number, value, _, _ in
                switch (number, value) {
                case (1, .bytes(let range)): id = CharacterID(encoded, in: range)
                case (2, .varint(let value)): length = Int(value & 0xFFFF_FFFF)
                case (3, .bytes(let range)): styleTimestamp = CharacterID(encoded, in: range)
                case (4, .varint(let value)): tombstoneValue = value
                case (5, .varint(let index)): children.append(Int(index & 0xFFFF_FFFF))
                case (5, .bytes(let range)): children += Self.unpack(encoded[range])
                default: break
                }
            }
            self.id = id
            self.length = length
            self.styleTimestamp = styleTimestamp
            self.tombstoneValue = tombstoneValue
            storedChildren = children
        }

        init(_ message: WireMessage) {
            // The bytes of a message always decode.
            self = (try? Self(encoded: message.encoded())) ?? Self(id: .init(replica: 0, clock: 0), length: 0, styleTimestamp: .init(replica: 0, clock: 0))
        }

        /// Creates a substring for newly inserted characters.
        init(id: CharacterID, length: Int, styleTimestamp: CharacterID) {
            encoded = WireMessage([
                .init(1, .bytes(id.message.encoded())),
                .init(2, .varint(UInt64(length))),
                .init(3, .bytes(styleTimestamp.message.encoded())),
            ]).encoded()
            self.id = id
            self.length = length
            self.styleTimestamp = styleTimestamp
            tombstoneValue = 0
            storedChildren = []
        }

        /// The stored message, with every field that Notes wrote.
        var message: WireMessage {
            (try? WireMessage(encoded)) ?? WireMessage()
        }

        /// Writes a changed message back to the bytes.
        private mutating func store(_ message: WireMessage) {
            encoded = message.encoded()
        }

        /// The identifier of the first character. Each following character has the next clock value.
        var id: CharacterID {
            didSet {
                guard id != oldValue else { return }
                var message = message
                id.write(to: &message, field: 1)
                store(message)
            }
        }

        /// The number of UTF-16 code units.
        var length: Int {
            didSet {
                guard length != oldValue else { return }
                var message = message
                message.setVarint(2, UInt64(length))
                store(message)
            }
        }

        /// The replica that last set the style of the characters, or deleted them, and its style clock at the time.
        var styleTimestamp: CharacterID {
            didSet {
                guard styleTimestamp != oldValue else { return }
                var message = message
                styleTimestamp.write(to: &message, field: 3)
                store(message)
            }
        }

        /// The stored tombstone value: 1 for deleted characters, and absent, read as 0, for the others.
        private(set) var tombstoneValue: UInt64

        var isTombstone: Bool {
            get { tombstoneValue != 0 }
            set {
                guard newValue != isTombstone else { return }
                var message = message
                message.set(4, newValue ? .varint(1) : nil)
                store(message)
                tombstoneValue = newValue ? 1 : 0
            }
        }

        /// The indexes of the substrings that follow this one in the insertion graph.
        ///
        /// Notes writes one field for each index. A packed field is read too, and written back packed.
        var children: [Int] {
            get { storedChildren }
            set {
                guard newValue != storedChildren else { return }
                storedChildren = newValue
                var message = message
                let isPacked = message.values(5).contains { if case .bytes = $0 { true } else { false } }
                if isPacked {
                    let packed = WireMessage(newValue.map { .init(0, .varint(UInt64($0))) }).encoded()
                    // Each entry is a key of 0 and a varint, so dropping the key bytes leaves the packed varints.
                    message.setRepeated(5, [.bytes(Self.droppingKeys(packed))])
                } else {
                    message.setRepeated(5, newValue.map { .varint(UInt64($0)) })
                }
                store(message)
            }
        }

        private var storedChildren: [Int]

        /// Adds 1 to each child index at or past a position, ahead of an insertion into the substring list there.
        ///
        /// An insertion near the start of a document changes the children of nearly every substring,
        /// so this writes the changed indexes straight to the bytes. The result is what setting ``children`` gives.
        mutating func shiftChildren(from threshold: Int) {
            guard storedChildren.contains(where: { $0 >= threshold }) else { return }
            let shifted = storedChildren.map { $0 >= threshold ? $0 + 1 : $0 }
            var output: [UInt8] = []
            output.reserveCapacity(encoded.count + shifted.count)
            var isPacked = false
            let bytes = encoded
            try? WireMessage.scan(bytes, in: 0 ..< bytes.count) { number, value, field, _ in
                switch (number, value) {
                case (5, .varint(let index)) where Int(index & 0xFFFF_FFFF) >= threshold:
                    // The key of field 5 with a varint, then the new index.
                    output.append(5 << 3)
                    WireMessage.appendVarint((index & 0xFFFF_FFFF) + 1, to: &output)
                case (5, .bytes):
                    isPacked = true
                default:
                    output += bytes[field]
                }
            }
            if isPacked {
                children = shifted
            } else {
                storedChildren = shifted
                encoded = output
            }
        }

        /// Whether this is the substring that ends the document.
        var isEnd: Bool {
            id.clock == Self.endClock
        }

        /// Whether the substring holds characters of the text.
        var isVisible: Bool {
            !isTombstone && !isEnd && length > 0
        }

        private static func unpack(_ packed: ArraySlice<UInt8>) -> [Int] {
            var values: [Int] = []
            var current: UInt64 = 0
            var shift: UInt64 = 0
            for byte in packed {
                current |= UInt64(byte & 0x7F) << min(shift, 63)
                shift += 7
                if byte & 0x80 == 0 {
                    values.append(Int(current & 0xFFFF_FFFF))
                    current = 0
                    shift = 0
                }
            }
            return values
        }

        private static func droppingKeys(_ encoded: [UInt8]) -> [UInt8] {
            var output: [UInt8] = []
            var atKey = true
            for byte in encoded {
                if atKey {
                    atKey = false
                } else {
                    output.append(byte)
                    atKey = byte & 0x80 == 0
                }
            }
            return output
        }
    }

    /// A device or session that edited the note, and how far its clocks have advanced.
    struct Replica: Hashable, Sendable {
        private(set) var message: WireMessage

        init(_ message: WireMessage) {
            self.message = message
        }

        /// Creates the entry of a replica that joins the document.
        init(uuid: [UInt8], textClock: Int, styleClock: Int) {
            message = WireMessage(
                [.init(1, .bytes(uuid))] + [textClock, styleClock].map { .init(2, .bytes(Self.clockMessage($0).encoded())) }
            )
        }

        /// The replica's UUID, in 16 bytes.
        var uuid: [UInt8] {
            message.bytes(1) ?? []
        }

        /// The replica's clocks: first the text clock, then the style clock.
        var clocks: [Int] {
            message.values(2).map { value in
                guard case .bytes(let bytes) = value else { return 0 }
                return (try? WireMessage(bytes))?.uint32(1) ?? 0
            }
        }

        /// The number of UTF-16 code units that the replica has inserted,
        /// which is the clock value of the next character that it inserts.
        var textClock: Int {
            get { clocks.first ?? 0 }
            set { setClock(0, newValue) }
        }

        /// The number of the replica's next style operation.
        var styleClock: Int {
            get { clocks.count > 1 ? clocks[1] : 0 }
            set { setClock(1, newValue) }
        }

        /// Whether a clock has a `subclock`, which no source has seen and the edit engine does not maintain.
        var hasSubclock: Bool {
            message.values(2).contains { value in
                guard case .bytes(let bytes) = value else { return false }
                return (try? WireMessage(bytes))?.contains(2) ?? false
            }
        }

        private mutating func setClock(_ index: Int, _ clock: Int) {
            var values = message.values(2)
            while values.count <= index {
                values.append(.bytes(Self.clockMessage(0).encoded()))
            }
            guard clocks.count <= index || clocks[index] != clock else { return }
            if case .bytes(let bytes) = values[index], var nested = try? WireMessage(bytes) {
                nested.setVarint(1, UInt64(clock))
                values[index] = .bytes(nested.encoded())
            } else {
                values[index] = .bytes(Self.clockMessage(clock).encoded())
            }
            message.setRepeated(2, values)
        }

        private static func clockMessage(_ clock: Int) -> WireMessage {
            WireMessage([.init(1, .varint(UInt64(clock)))])
        }
    }

    /// A run of characters with the same attributes, as stored.
    ///
    /// The run keeps every field, including those that TopoText does not read.
    struct AttributeRun: Hashable, Sendable {
        /// The stored message. ``length`` holds its length, read once, and writes each change back to it.
        private(set) var message: WireMessage

        init(_ message: WireMessage) {
            self.message = message
            length = message.int32(1) ?? 0
        }

        /// Creates a run with a length and, optionally, a paragraph style.
        init(length: Int, paragraphStyle: WireMessage? = nil) {
            var message = WireMessage([.init(1, .varint(UInt64(length)))])
            if let paragraphStyle {
                message.setMessage(2, paragraphStyle)
            }
            self.init(message)
        }

        /// The number of UTF-16 code units, or a negative number if the stored length is negative.
        var length: Int {
            didSet {
                if length != oldValue { message.setVarint(1, UInt64(length)) }
            }
        }

        var paragraphStyle: WireMessage? {
            get { message.message(2) }
            set { message.set(2, newValue.map { .bytes($0.encoded()) }) }
        }

        /// The `style` value of the paragraph style: 100 bulleted, 102 numbered, 103 checklist, and so on.
        var styleType: Int? {
            paragraphStyle?.int32(1)
        }

        /// The checklist state, a `Todo` message with `todoUUID` [1] and `done` [2].
        var todo: WireMessage? {
            paragraphStyle?.message(5)
        }

        /// Whether the run stands for an attachment: it has `attachmentInfo` [12] or `systemAttachmentInfo` [15].
        var hasAttachment: Bool {
            message.contains(12) || message.contains(15)
        }

        /// The type of the run's attachment, such as `com.apple.notes.table`.
        var attachmentType: String? {
            message.message(12)?.string(2)
        }

        /// Returns whether two runs have the same attributes, whatever their lengths.
        func hasSameAttributes(as other: AttributeRun) -> Bool {
            var first = message
            var second = other.message
            first.set(1, nil)
            second.set(1, nil)
            return first.fields.elementsEqual(second.fields) { $0.number == $1.number && $0.value == $1.value }
        }

        /// A copy of the run for text that is inserted next to it:
        /// the same attributes, without the attachment and without the link.
        func copyForAdjacentText() -> AttributeRun {
            var copy = self
            for number in [9, 12, 15] {
                copy.message.set(number, nil)
            }
            return copy
        }
    }

    /// The document, the version, and the string, as decoded. The typed properties below replace parts of them on encoding.
    private var document: WireMessage
    private var version: WireMessage
    private var string: WireMessage
    private var vectorTimestamp: WireMessage?
    /// The text as decoded, to tell whether an edit changed it.
    private let storedText: String

    /// The number of `Version` messages in the document. Notes writes one.
    let versionCount: Int
    /// The `minimumSupportedVersion` of the version, or `nil` if the field is absent, which reads as 0.
    ///
    /// Each of the 1,566 documents of the run that <doc:NoteStore> records has 0.
    /// A higher value says that the document needs a reader that knows a later format.
    let minimumSupportedVersion: UInt64?
    /// Whether the stored text is valid UTF-8, so that ``text`` holds it without loss.
    let textIsValid: Bool

    /// The text of the note. Positions in it count UTF-16 code units.
    var text: String
    /// The substrings, in the order of the text. The list is empty for a document without merge state.
    var substrings: [Substring]
    /// The replicas of the vector timestamp. A character's `replica` is a 1-based index into them.
    var replicas: [Replica]
    var runs: [AttributeRun]

    /// Decodes the contents of `ZICNOTEDATA.ZDATA`.
    /// - Throws: A ``FormatError`` if the data is not a gzip-compressed note document.
    init(data: Data) throws {
        try self.init(protobuf: Array(try data.gunzipped()))
    }

    /// Decodes a decompressed note document.
    /// - Throws: ``FormatError/unrecognized`` if the bytes have no note,
    ///   or ``FormatError/malformed`` if the bytes or a message of the merge state don't decode.
    init(protobuf: [UInt8]) throws {
        document = try WireMessage(protobuf)
        // Where a field repeats, ``NoteDocument`` reads its last value, and so does this.
        guard let versionBytes = document.bytes(2) else {
            throw FormatError.unrecognized
        }
        version = try WireMessage(versionBytes)
        guard let stringBytes = version.bytes(3) else {
            throw FormatError.unrecognized
        }
        string = try WireMessage(stringBytes)
        versionCount = document.values(2).count
        minimumSupportedVersion = version.varint(2)

        let textBytes = string.bytes(2) ?? []
        text = String(decoding: textBytes, as: UTF8.self)
        storedText = text
        textIsValid = Array(text.utf8) == textBytes

        func messages(_ message: WireMessage, _ number: Int) throws -> [WireMessage] {
            try message.values(number).map { value in
                guard case .bytes(let bytes) = value else { throw FormatError.malformed }
                return try WireMessage(bytes)
            }
        }
        substrings = try string.values(3).map { value in
            guard case .bytes(let bytes) = value else { throw FormatError.malformed }
            return try Substring(encoded: bytes)
        }
        runs = try messages(string, 5).map(AttributeRun.init)
        if let bytes = string.bytes(4) {
            let timestamp = try WireMessage(bytes)
            vectorTimestamp = timestamp
            replicas = try messages(timestamp, 1).map(Replica.init)
        } else {
            replicas = []
        }
    }

    /// The decompressed bytes of the document.
    func protobuf() -> [UInt8] {
        var string = string
        // Swift compares strings by canonical equivalence, so "é" equals "e" with U+0301.
        // The stored bytes must be the text's own, so compare the bytes.
        if !text.utf8.elementsEqual(storedText.utf8) {
            string.set(2, .bytes(Array(text.utf8)))
        }
        string.setRepeated(3, substrings.map { .bytes($0.encoded) })
        if vectorTimestamp != nil || !replicas.isEmpty {
            var timestamp = vectorTimestamp ?? WireMessage()
            timestamp.setRepeated(1, replicas.map { .bytes($0.message.encoded()) })
            string.setMessage(4, timestamp)
        }
        string.setRepeated(5, runs.map { .bytes($0.message.encoded()) })

        var version = version
        version.setMessage(3, string)
        var document = document
        document.setMessage(2, version)
        return document.encoded()
    }

    /// The contents for `ZICNOTEDATA.ZDATA`: the document, gzip-compressed.
    func data() throws -> Data {
        try Data(protobuf()).gzipped()
    }

    /// Whether the document has a vector timestamp. Table cells have none.
    var hasVectorTimestamp: Bool {
        vectorTimestamp != nil
    }

    /// The messages of the document that the edit engine can write, for ``WireMessage/reencoded(as:)``.
    static let schema: WireMessage.Schema = {
        let characterID = WireMessage.Schema()
        let substring = WireMessage.Schema(nested: [1: characterID, 3: characterID])
        let vectorTimestamp = WireMessage.Schema(nested: [1: .init(nested: [2: .init()])])
        let paragraphStyle = WireMessage.Schema(nested: [5: .init()])
        let run = WireMessage.Schema(nested: [2: paragraphStyle, 3: .init(), 10: .init(), 12: .init()])
        let string = WireMessage.Schema(nested: [3: substring, 4: vectorTimestamp, 5: run])
        return WireMessage.Schema(nested: [2: .init(nested: [3: string])])
    }()
}

// MARK: - Text and paragraphs

extension StoredNote {
    /// A paragraph of the text, in UTF-16 code units.
    struct ParagraphRange: Hashable, Sendable {
        /// The paragraph's characters, without its line feed.
        var content: Range<Int>
        /// Whether a line feed ends the paragraph. The last paragraph can lack one.
        var hasLineFeed: Bool

        /// The paragraph's characters and its line feed.
        var full: Range<Int> {
            content.lowerBound ..< content.upperBound + (hasLineFeed ? 1 : 0)
        }
    }

    /// The length of the text in UTF-16 code units.
    var length: Int {
        text.utf16.count
    }

    /// The paragraphs of the text, as ``NoteDocument/paragraphs`` and ``Note/Content/paragraphs`` count them:
    /// a line feed ends a paragraph, and the text after the last line feed is a paragraph only if it is not empty.
    var paragraphRanges: [ParagraphRange] {
        var ranges: [ParagraphRange] = []
        var start = 0
        var offset = 0
        for unit in text.utf16 {
            if unit == 0x0A {
                ranges.append(ParagraphRange(content: start ..< offset, hasLineFeed: true))
                start = offset + 1
            }
            offset += 1
        }
        if start < offset {
            ranges.append(ParagraphRange(content: start ..< offset, hasLineFeed: false))
        }
        return ranges
    }

    /// The index of the run that covers the character at an offset, and the offset of the run's first character.
    func run(at offset: Int) -> (index: Int, start: Int)? {
        var start = 0
        for (index, run) in runs.enumerated() {
            if offset < start + run.length {
                return offset >= start ? (index, start) : nil
            }
            start += run.length
        }
        return nil
    }
}

// MARK: - Invariants

extension StoredNote {
    /// A property of a stored document that the edit engine relies on. A document that lacks one of them is not edited.
    typealias Invariant = NoteEditError.Invariant

    /// The invariants that the document lacks.
    var brokenInvariants: [Invariant] {
        var broken: Set<Invariant> = []
        func require(_ invariant: Invariant, _ condition: Bool) {
            if !condition { broken.insert(invariant) }
        }
        let length = self.length

        require(.oneVersion, versionCount == 1)
        require(.supportedVersion, (minimumSupportedVersion ?? 0) == 0)
        require(.validText, textIsValid)
        require(.vectorTimestamp, hasVectorTimestamp)
        require(.replicaIdentifiers, replicas.allSatisfy { $0.uuid.count == 16 })
        require(.uniqueReplicas, Set(replicas.map(\.uuid)).count == replicas.count)
        require(.noSubclock, !replicas.contains(where: \.hasSubclock))
        require(.originSubstring, substrings.first.map { $0.id == CharacterID(replica: 0, clock: 0) && $0.length == 0 } ?? false)
        require(
            .endSubstring,
            substrings.last.map { $0.isEnd && $0.id.replica == 0 && $0.length == 0 } ?? false && !substrings.dropLast().contains(where: \.isEnd)
        )
        require(.substringLengths, substrings.reduce(0) { $0 + ($1.isTombstone ? 0 : $1.length) } == length)
        require(.runLengths, runs.allSatisfy { $0.length >= 0 } && runs.reduce(0) { $0 + $1.length } == length)

        let limit = 1 << 31
        require(.clockRange, replicas.allSatisfy { $0.clocks.allSatisfy { $0 < limit } })
        let textClocks = replicas.map(\.textClock)
        // This loop runs for every substring of every document that is edited, so it keeps plain flags.
        var replicaIndexes = true
        var tombstoneValues = true
        var clockRange = true
        var textClockValues = true
        var childIndexes = true
        let replicaCount = replicas.count
        let count = substrings.count
        for index in 0 ..< count {
            let substring = substrings[index]
            let id = substring.id
            let timestamp = substring.styleTimestamp
            if id.replica > replicaCount || timestamp.replica > replicaCount { replicaIndexes = false }
            if substring.tombstoneValue > 1 { tombstoneValues = false }
            if id.clock == Substring.endClock {
                // Nothing comes after the end marker. A child of it would be an edge back into the text.
                if !substring.children.isEmpty { childIndexes = false }
                continue
            }
            // The index 0 is for the origin and the end marker. A character with it could share the origin's identifier.
            if id.replica < 1, substring.length > 0 { replicaIndexes = false }
            if id.clock + substring.length >= limit || timestamp.clock >= limit { clockRange = false }
            if id.replica >= 1, id.replica <= replicaCount, id.clock + substring.length > textClocks[id.replica - 1] {
                textClockValues = false
            }
            let children = substring.children
            if children.isEmpty { childIndexes = false }
            for child in children where child <= index || child >= count {
                childIndexes = false
            }
        }
        require(.replicaIndexes, replicaIndexes)
        require(.tombstoneValues, tombstoneValues)
        require(.clockRange, clockRange)
        require(.textClocks, textClockValues)
        require(.childIndexes, childIndexes)
        // Children that come later in the list can still leave a substring that no other one points to.
        require(.reachableSubstrings, reachesEverySubstring)
        require(.uniqueIdentifiers, hasUniqueIdentifiers)
        return Invariant.allCases.filter(broken.contains)
    }
    /// Whether the child indexes lead from the first substring to every other one.
    var reachesEverySubstring: Bool {
        guard !substrings.isEmpty else { return true }
        var reached = Array(repeating: false, count: substrings.count)
        reached[0] = true
        var count = 1
        // Where each child comes later in the list, one pass in order reaches all that can be reached.
        for index in substrings.indices where reached[index] {
            for child in substrings[index].children where child >= 0 && child < reached.count && !reached[child] {
                reached[child] = true
                count += 1
            }
        }
        return count == substrings.count
    }

    /// Whether each character that the document records, deleted or not, has an identifier of its own:
    /// no two substrings of one replica hold the same clock value.
    var hasUniqueIdentifiers: Bool {
        // For each replica, the clock ranges as numbers that sort by their first clock:
        // a clock is below 2 to the power 32, and a length that an invariant allows is below 2 to the power 31.
        let mask = (1 << 31) - 1
        var ranges: [[Int]] = Array(repeating: [], count: replicas.count + 1)
        for substring in substrings where !substring.isEnd && substring.length > 0 {
            let id = substring.id
            // Another invariant covers an identifier that names no replica.
            guard id.replica >= 0, id.replica < ranges.count else { continue }
            ranges[id.replica].append(id.clock << 31 | min(substring.length, mask))
        }
        for index in ranges.indices {
            ranges[index].sort()
            var end = 0
            for range in ranges[index] {
                let clock = range >> 31
                if clock < end { return false }
                end = clock + (range & mask)
            }
        }
        return true
    }
}
