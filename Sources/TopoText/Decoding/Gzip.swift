import Foundation

extension Data {
    /// Decompresses gzip data (RFC 1952), the format of note contents and tables.
    ///
    /// Foundation's zlib algorithm reads raw deflate data (RFC 1951),
    /// so this method parses the gzip header and trailer around it,
    /// and checks the trailer's CRC-32 and size.
    /// - Throws: ``FormatError/unrecognized`` if the data does not start with the gzip signature,
    ///   or ``FormatError/malformed`` if it is damaged or truncated.
    func gunzipped() throws -> Data {
        // Some rows hold other formats, such as property lists, which aren't note contents.
        guard count >= 2, self[startIndex] == 0x1F, self[startIndex + 1] == 0x8B else {
            throw FormatError.unrecognized
        }
        // Deflate is the only compression method gzip defines.
        guard count >= 18, self[startIndex + 2] == 8 else {
            throw FormatError.malformed
        }

        // The header is 10 bytes, followed by optional fields that its flags announce.
        let flags = self[startIndex + 3]
        var offset = startIndex + 10

        func skipZeroTerminatedField() throws {
            guard let terminator = self[offset...].firstIndex(of: 0) else {
                throw FormatError.malformed
            }
            offset = terminator + 1
        }

        if flags & 0x04 != 0 {  // FEXTRA
            guard endIndex - offset >= 2 else { throw FormatError.malformed }
            offset += 2 + (Int(self[offset]) | Int(self[offset + 1]) << 8)
            guard offset <= endIndex else { throw FormatError.malformed }
        }
        if flags & 0x08 != 0 {  // FNAME
            try skipZeroTerminatedField()
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            try skipZeroTerminatedField()
        }
        if flags & 0x02 != 0 {  // FHCRC
            offset += 2
        }
        // The deflate stream ends 8 bytes before the end, ahead of the CRC-32 and the size.
        guard endIndex - offset >= 8 else { throw FormatError.malformed }

        let deflated = self[offset ..< endIndex - 8]
        let inflated: Data
        do {
            inflated = try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw FormatError.malformed
        }

        let trailer = self[(endIndex - 8)...].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let expectedCRC = UInt32(truncatingIfNeeded: trailer)
        let expectedSize = UInt32(truncatingIfNeeded: trailer >> 32)
        guard UInt32(truncatingIfNeeded: inflated.count) == expectedSize, inflated.crc32() == expectedCRC else {
            throw FormatError.malformed
        }
        return inflated
    }

    /// The CRC-32 checksum that gzip stores in its trailer.
    func crc32() -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        withUnsafeBytes { buffer in
            for byte in buffer {
                crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// The lookup table for the CRC-32 polynomial that gzip uses, in reversed bit order.
private let crc32Table: [UInt32] = (0 ..< 256).map { index in
    var value = UInt32(index)
    for _ in 0 ..< 8 {
        value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
    }
    return value
}
