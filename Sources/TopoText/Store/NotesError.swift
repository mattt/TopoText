import Foundation

/// An error that occurs when TopoText reads the Notes database.
///
/// The error descriptions are in English; TopoText does not localize them.
public enum NotesError: LocalizedError, Hashable {
    /// The folder does not contain a `NoteStore.sqlite` database.
    case storeNotFound
    /// The folder, the database, or its write-ahead log files cannot be read.
    case storeNotReadable
    /// The database does not have the tables or entities that TopoText reads.
    case unsupportedSchema
    /// Notes holds a lock on the database.
    case databaseBusy
    /// The operation did not finish within ``Store/Configuration/timeLimit``.
    case timedOut
    /// SQLite reported an error, with its message.
    case queryFailed(String)
    /// The connection to the database is closed,
    /// for example because a snapshot is used after its closure returns.
    case connectionClosed
    /// A cursor comes from a different database than the one that is open.
    case storeChanged
    /// The database has no folder with the identifier,
    /// or the folder is a smart folder, which holds no notes.
    case folderNotFound(Folder.ID)
    /// The database has no note with the identifier that Notes would list.
    case noteNotFound(Note.ID)
    /// The note is locked with a password, so its contents are encrypted.
    case noteLocked(Note.ID)
    /// The database has no contents for the note,
    /// for example because the note has not finished syncing to this Mac.
    case contentNotFound(Note.ID)
    /// The note's contents are in a format that TopoText does not read.
    case unsupportedContent(Note.ID)
    /// The note's contents are damaged or truncated.
    case malformedContent(Note.ID)
    /// The database has no attachment with the identifier.
    case attachmentNotFound(Note.Attachment.ID)

    public var errorDescription: String? {
        switch self {
        case .storeNotFound:
            return "The selected folder does not contain a Notes database."
        case .storeNotReadable:
            return "The Notes database cannot be read. The database and its write-ahead log files must be readable."
        case .unsupportedSchema:
            return "The Notes database uses an unsupported schema."
        case .databaseBusy:
            return "Notes is using the database. Try again later."
        case .timedOut:
            return "Reading the Notes database stopped at the time limit. A search with more specific filters can finish sooner."
        case .queryFailed(let message):
            return "The Notes database cannot be read: \(message)"
        case .connectionClosed:
            return "The connection to the Notes database is closed."
        case .storeChanged:
            return "The cursor is from a different Notes database. Search again to get a current cursor."
        case .folderNotFound(let id):
            return "No folder has the identifier \(id)."
        case .noteNotFound(let id):
            return "No note has the identifier \(id)."
        case .noteLocked(let id):
            return "The note with the identifier \(id) is locked with a password, so its contents can't be read."
        case .contentNotFound(let id):
            return "The note with the identifier \(id) has no contents on this Mac. It may not have finished syncing."
        case .unsupportedContent(let id):
            return "The contents of the note with the identifier \(id) are in a format that TopoText doesn't read."
        case .malformedContent(let id):
            return "The contents of the note with the identifier \(id) are damaged."
        case .attachmentNotFound(let id):
            return "No attachment has the identifier \(id)."
        }
    }
}
