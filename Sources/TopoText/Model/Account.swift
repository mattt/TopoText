import Foundation

/// An account in the Notes app, such as iCloud or On My Mac.
public struct Account: Sendable, Hashable, Identifiable {
    /// The identifier of an account.
    public typealias ID = Identifier<Account>

    /// The account's identifier, such as a UUID string or `LocalAccount` for On My Mac.
    ///
    /// Notes names the account's folder of attachment files after this identifier,
    /// as in `Accounts/<identifier>/Media`.
    public let id: ID
    /// The name of the account that Notes shows, such as `iCloud`, if the database has one.
    public let name: String?
}
