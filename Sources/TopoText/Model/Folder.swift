import Foundation

/// A folder in the Notes app.
///
/// ``Store/folders()`` lists every folder except smart folders,
/// which collect notes by a query instead of holding them.
public struct Folder: Sendable, Hashable, Identifiable {
    /// The identifier of a folder.
    public typealias ID = Identifier<Folder>

    /// The folder's identifier.
    ///
    /// The default folder of an account has an identifier that starts with `DefaultFolder`,
    /// and Recently Deleted has one that starts with `TrashFolder`.
    public let id: ID
    /// The name of the folder.
    ///
    /// When the database has no name for the folder,
    /// as for some default and Recently Deleted folders,
    /// the name is the English name that Notes shows: `Notes` or `Recently Deleted`.
    public let name: String
    /// The folder that this folder is nested in, if any.
    public let parentID: ID?
    /// The account that owns the folder, if the database records one.
    public let account: Account?
    /// A Boolean value that indicates whether this is an account's Recently Deleted folder.
    public let isRecentlyDeleted: Bool
    /// The number of notes directly in the folder, not counting nested folders.
    public let noteCount: Int
}
