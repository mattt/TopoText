import Foundation

/// A smart folder in the Notes app: a folder that collects notes by a query.
///
/// A smart folder holds no notes of its own, so it is not a ``Folder``
/// and ``Store/folders()`` leaves it out.
/// ``Store/smartFolders()`` lists them with the queries that define them.
public struct SmartFolder: Sendable, Hashable, Identifiable {
    /// The identifier of a smart folder.
    public typealias ID = Identifier<SmartFolder>

    /// The smart folder's identifier.
    public let id: ID
    /// The name of the smart folder, or an empty string if the database has none.
    public let name: String
    /// The folder that the smart folder is nested in, if any.
    public let parentID: Folder.ID?
    /// The account that owns the smart folder, if the database records one.
    public let account: Account?
    /// The query that selects the folder's notes, as the text that Notes stores.
    ///
    /// A smart folder that ``Store/smartFolders()`` returns never has an empty query.
    /// TopoText doesn't interpret the query or check that it is valid JSON.
    /// On macOS 27.0.1, Notes stored a smart folder with one tag rule as
    /// `{"type":{"and":[{"deleted":false},{"and":[{"and":[{"deleted":false},{"and":[{"tag":"SMART"}]}]}]}]},"entity":"note"}`.
    /// The rule sits in nested `and` clauses after the first `deleted` clause,
    /// and the tag is in capitals, without its `#`.
    /// Other kinds of rules have not been checked against Notes,
    /// so don't depend on this form.
    public let query: String

    /// Creates a smart folder.
    /// - Parameters:
    ///   - id: The smart folder's identifier.
    ///   - name: The name of the smart folder.
    ///   - parentID: The folder that the smart folder is nested in, if any.
    ///   - account: The account that owns the smart folder, if any.
    ///   - query: The stored query, as JSON text.
    public init(id: ID, name: String, parentID: Folder.ID? = nil, account: Account? = nil, query: String) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.account = account
        self.query = query
    }
}
