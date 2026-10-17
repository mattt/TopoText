import Foundation

/// A note in the Notes app, without its contents.
///
/// Read the contents with ``Store/content(for:)``.
public struct Note: Sendable, Hashable, Identifiable {
    /// The identifier of a note.
    public typealias ID = Identifier<Note>

    /// The note's identifier, an uppercase UUID string.
    ///
    /// The identifier is the same on every device that syncs the note,
    /// and it is the one that `applenotes:note/<identifier>` links use.
    public let id: ID
    /// The title that Notes shows for the note, taken from its first line.
    ///
    /// The title can be empty.
    public let title: String
    /// The preview that Notes shows below the title, or `nil` if there is none.
    ///
    /// The preview of a locked note is always `nil`,
    /// because the stored preview can still hold text from before the note was locked.
    public let snippet: String?
    /// The folder that holds the note.
    public let folderID: Folder.ID?
    /// A Boolean value that indicates whether the note is in Recently Deleted.
    public let isRecentlyDeleted: Bool
    /// The date that the note was created, if the database records one.
    public let creationDate: Date?
    /// The date that the note was last changed, if the database records one.
    public let modificationDate: Date?
    /// A Boolean value that indicates whether the note is pinned to the top of its folder.
    public let isPinned: Bool
    /// A Boolean value that indicates whether the note is locked with a password.
    ///
    /// The contents of a locked note are encrypted, and TopoText doesn't read them.
    public let isLocked: Bool

    /// The note's row in `ZICCLOUDSYNCINGOBJECT`.
    let rowID: Int64
    /// The key that orders search results: the modification date in Core Data seconds,
    /// or ``Note/missingDateKey`` if the note has none.
    let sortKey: Double
    /// The UUID of the database, from `Z_METADATA`, or an empty string if it has none.
    let store: String

    /// The sort key of notes without a modification date, which sort after every other note.
    static let missingDateKey = -1.0e308
}

extension Note {
    /// A search of the notes in the Notes app.
    ///
    /// Filters combine with AND.
    /// Results are ordered by modification date, newest first;
    /// notes without a modification date come last.
    ///
    /// Without a ``query``, a request reads only note metadata.
    /// With a query, a request decodes the contents of each candidate note in turn,
    /// until it finds ``limit`` matches or has examined ``scanLimit`` notes.
    public struct FetchRequest: Sendable, Hashable {
        /// The number of results that a request returns when it does not set a limit.
        public static let defaultLimit = 30
        /// The largest limit that a request can set.
        public static let maximumLimit = 100
        /// The number of notes that a request examines when it does not set a scan limit.
        public static let defaultScanLimit = 1_000
        /// The largest scan limit that a request can set.
        public static let maximumScanLimit = 10_000

        /// Text to find in the title, preview, or contents,
        /// without regard to case or diacritics.
        ///
        /// The contents include the text of tags, mentions, links, tables,
        /// and link cards, the names of attachments,
        /// and the text that Notes recognizes in images and handwriting.
        /// Locked notes match by title alone.
        /// A query that is empty or only white space matches every note.
        public var query: String?
        /// The folders to search, or `nil` to search every folder.
        ///
        /// A request searches only the notes directly in each folder, not in nested folders.
        public var folderIDs: Set<Folder.ID>?
        /// A Boolean value that indicates whether a search of every folder includes Recently Deleted.
        ///
        /// When ``folderIDs`` is set, the request searches the folders it names, and ignores this value.
        public var includesRecentlyDeleted: Bool
        /// The earliest modification date to include.
        public var startDate: Date?
        /// The modification date at which the range ends.
        ///
        /// The range excludes notes last changed at this date.
        public var endDate: Date?
        /// The maximum number of results, from 1 through ``maximumLimit``.
        public var limit: Int
        /// The maximum number of notes that one request examines,
        /// from 1 through ``maximumScanLimit``.
        ///
        /// The limit bounds the work of a search with a ``query``.
        /// When a search reaches it, ``Store/SearchResult/nextCursor``
        /// continues after the last note it examined.
        public var scanLimit: Int
        /// The position after which results start, or `nil` for the first page.
        ///
        /// Use ``Store/SearchResult/nextCursor`` from the previous page.
        public var cursor: Cursor?

        /// Creates a search request.
        /// - Parameters:
        ///   - query: Text to find in the title, preview, or contents.
        ///   - folderIDs: The folders to search, or `nil` to search every folder.
        ///   - includesRecentlyDeleted: Whether a search of every folder includes Recently Deleted.
        ///   - startDate: The earliest modification date to include.
        ///   - endDate: The modification date at which the range ends.
        ///   - limit: The maximum number of results, from 1 through ``maximumLimit``.
        ///   - scanLimit: The maximum number of notes to examine, from 1 through ``maximumScanLimit``.
        ///   - cursor: The position after which results start, or `nil` for the first page.
        public init(
            query: String? = nil,
            folderIDs: Set<Folder.ID>? = nil,
            includesRecentlyDeleted: Bool = false,
            startDate: Date? = nil,
            endDate: Date? = nil,
            limit: Int = FetchRequest.defaultLimit,
            scanLimit: Int = FetchRequest.defaultScanLimit,
            cursor: Cursor? = nil
        ) {
            self.query = query
            self.folderIDs = folderIDs
            self.includesRecentlyDeleted = includesRecentlyDeleted
            self.startDate = startDate
            self.endDate = endDate
            self.limit = limit
            self.scanLimit = scanLimit
            self.cursor = cursor
        }

        /// The query without surrounding white space, or `nil` if nothing remains.
        var trimmedQuery: String? {
            guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return nil
            }
            return query
        }

        /// Checks the limits and the date range.
        /// - Throws: A ``ValidationError`` that describes the first invalid value.
        func validate() throws {
            guard (1 ... Self.maximumLimit).contains(limit) else {
                throw ValidationError.limitOutOfRange
            }
            guard (1 ... Self.maximumScanLimit).contains(scanLimit) else {
                throw ValidationError.scanLimitOutOfRange
            }
            if let startDate, let endDate, startDate >= endDate {
                throw ValidationError.invalidDateRange
            }
        }
    }
}

extension Note.FetchRequest {
    /// A position in search results, after which the next page starts.
    ///
    /// A cursor names the last note of a page by its modification date and row,
    /// so notes that change between requests do not shift later pages, as an offset would.
    /// A note that changes moves to the front of the results, so a later page leaves it out.
    /// The cursor also names the database, so that it can't be used with another one.
    ///
    /// Get a cursor from ``Store/SearchResult/nextCursor``.
    /// Its string form round-trips through `init(_:)`, and it encodes as its string form;
    /// treat the string as opaque.
    public struct Cursor: Sendable, Hashable, LosslessStringConvertible, Codable {
        /// The UUID of the database, or an empty string if it has none.
        let store: String
        /// The sort key of the note.
        let sortKey: Double
        /// The note's row.
        let rowID: Int64

        /// Creates a cursor that starts the next page after a note.
        init(after note: Note) {
            store = note.store
            sortKey = note.sortKey
            rowID = note.rowID
        }

        public init?(_ description: String) {
            let parts = description.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                let sortKey = Double(parts[1]), sortKey.isFinite,
                let rowID = Int64(parts[2]), rowID > 0
            else { return nil }
            store = String(parts[0])
            self.sortKey = sortKey
            self.rowID = rowID
        }

        public var description: String {
            "\(store):\(sortKey):\(rowID)"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let cursor = Self(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(string)\" is not a valid cursor.")
            }
            self = cursor
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }
    }
}
