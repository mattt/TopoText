import Foundation

/// The identifier that Notes assigns to an account, folder, note, or attachment.
///
/// Notes stores the identifier in the `ZIDENTIFIER` column.
/// For notes and attachments it is an uppercase UUID string,
/// which stays the same on every device that syncs the note
/// and appears in `applenotes:` links.
/// Some folders and accounts have names instead,
/// such as `DefaultFolder-CloudKit` or `LocalAccount`.
///
/// The type parameter keeps identifiers of different entities apart,
/// so that a folder identifier can't be passed where a note identifier is expected.
/// The string form of an identifier is the value of the `ZIDENTIFIER` column,
/// and an empty string is not an identifier.
/// An identifier encodes as its string form.
public struct Identifier<Entity>: Sendable, Hashable, LosslessStringConvertible {
    private let value: String

    public init?(_ description: String) {
        guard !description.isEmpty else { return nil }
        value = description
    }

    public var description: String {
        value
    }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let identifier = Self(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "An identifier can't be empty.")
        }
        self = identifier
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Returns the identifier of the note that an `applenotes:` link opens,
/// or `nil` if the string is not a link to a note.
///
/// Links to other notes have the form `applenotes:note/<identifier>`,
/// optionally followed by a query such as `?ownerIdentifier=…`.
/// Links can carry the identifier in lowercase; the result is in uppercase, as Notes stores it.
func noteID(inLink link: String) -> Note.ID? {
    guard let components = URLComponents(string: link), components.scheme?.lowercased() == "applenotes" else {
        return nil
    }
    // `applenotes:note/<id>` has the path `note/<id>`; `applenotes://note/<id>` has the host `note`.
    var parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
    if let host = components.host {
        parts.insert(Substring(host), at: 0)
    }
    guard parts.count == 2, parts[0].lowercased() == "note",
        !parts[1].isEmpty, parts[1].allSatisfy({ $0 == "-" || $0.isHexDigit })
    else { return nil }
    return Note.ID(parts[1].uppercased())
}
