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
    /// The text is never empty.
    /// TopoText doesn't interpret the query or check that it is valid JSON.
    /// One project reports that the query looks like
    /// `{"entity":"note","type":{"and":[{"deleted":false}, …]}}`,
    /// with the folder's rules after the `deleted` clause.
    /// That form is an example that has not been checked against Notes;
    /// don't depend on it.
    public let query: String

    /// Creates a smart folder.
    /// - Parameters:
    ///   - id: The smart folder's identifier.
    ///   - name: The name of the smart folder.
    ///   - parentID: The folder that the smart folder is nested in, if any.
    ///   - account: The account that owns the smart folder, if any.
    ///   - query: The stored query text, which is not empty.
    init(id: ID, name: String, parentID: Folder.ID? = nil, account: Account? = nil, query: String) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.account = account
        self.query = query
    }
}
