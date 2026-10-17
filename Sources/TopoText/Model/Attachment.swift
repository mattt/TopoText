import Foundation
import UniformTypeIdentifiers

extension Note {
    /// An attachment in a note, such as a tag, a table, an image, or a link card.
    ///
    /// Each attachment stands in the note's text as an object replacement character (U+FFFC).
    /// Notes keeps inline attachments, such as tags and mentions, and other attachments,
    /// such as images and tables, as rows of different entities;
    /// an attachment carries the values of whichever row has its identifier.
    /// If the database has no row for the attachment, as is common for deleted attachments,
    /// only ``id`` and ``typeIdentifier`` have values.
    ///
    /// Use ``Store/fileURL(for:)`` to find the file of an attachment, such as an image.
    public struct Attachment: Sendable, Hashable, Identifiable {
        /// The identifier of an attachment.
        public typealias ID = Identifier<Attachment>

        /// The kind of an attachment.
        public enum Kind: Sendable, Hashable {
            /// A tag, such as `#groceries`. ``Attachment/displayText`` has its text.
            case hashtag
            /// A mention of a person who shares the note.
            /// ``Attachment/displayText`` has the text that Notes shows,
            /// and ``Attachment/tokenIdentifier`` identifies the participant.
            case mention
            /// An inline link to another note.
            /// ``Attachment/displayText`` has the label,
            /// ``Attachment/tokenIdentifier`` has the `applenotes:note/…` link,
            /// and ``Attachment/linkedNoteID`` has the identifier of the note.
            case noteLink
            /// The result of a calculation or a graph expression.
            /// ``Attachment/displayText`` has its text.
            case calculation
            /// Another kind of inline text attachment. ``Attachment/displayText`` has its text.
            case inlineText
            /// A table. ``Attachment/table`` has its cells, and ``Attachment/summary`` its plain text.
            case table
            /// A link card for a web page. ``Attachment/url`` has its URL, and ``Attachment/title`` the page title.
            case webLink
            /// A drawing or sketch.
            case drawing
            /// A scanned document.
            case scannedDocument
            /// An image.
            case image
            /// A PDF document.
            case pdf
            /// An audio recording.
            case audio
            /// A video.
            case video
            /// A contact card.
            case contact
            /// Another kind of file.
            case file

            /// A Boolean value that indicates whether the attachment is text within a line,
            /// such as a tag, rather than an object such as an image.
            public var isInline: Bool {
                switch self {
                case .hashtag, .mention, .noteLink, .calculation, .inlineText: return true
                default: return false
                }
            }
        }

        /// The type identifier of a table.
        static let tableType = "com.apple.notes.table"
        /// The prefix of the type identifiers of inline attachments.
        static let inlineTypePrefix = "com.apple.notes.inlinetextattachment."

        /// The attachment's identifier, an uppercase UUID string.
        public let id: ID
        /// The uniform type identifier of the attachment, such as `public.jpeg` or `com.apple.notes.table`.
        ///
        /// The value comes from the attachment's row, or from the note's reference to the attachment
        /// if the row has none.
        public internal(set) var typeIdentifier: String?
        /// The text that an inline attachment shows, such as `#groceries` for a tag.
        public let displayText: String?
        /// The identifier that an inline attachment refers to:
        /// the `applenotes:note/…` link of a link to another note,
        /// or the participant of a mention.
        public let tokenIdentifier: String?
        /// The title of the attachment, such as the page title of a link card or the name of a file.
        public let title: String?
        /// The URL of a link card.
        public let url: URL?
        /// The name of the file that holds the attachment's media, if it has any.
        public let fileName: String?
        /// The plain-text summary that Notes keeps for some attachments, such as tables.
        public let summary: String?
        /// The text that Notes recognizes in an image or a scanned document.
        public let recognizedText: String?
        /// The text that Notes recognizes in handwriting in a drawing.
        public let handwritingText: String?
        /// The cells of a table, or `nil` if the attachment is not a table or its cells can't be decoded.
        ///
        /// When a table can't be decoded, ``summary`` can still have its text.
        public internal(set) var table: Table?

        /// Creates an attachment.
        /// - Parameters:
        ///   - id: The attachment's identifier.
        ///   - typeIdentifier: The uniform type identifier of the attachment.
        ///   - displayText: The text that an inline attachment shows.
        ///   - tokenIdentifier: The identifier that an inline attachment refers to.
        ///   - title: The title of the attachment.
        ///   - url: The URL of a link card.
        ///   - fileName: The name of the file that holds the attachment's media.
        ///   - summary: The plain-text summary that Notes keeps for the attachment.
        ///   - recognizedText: The text that Notes recognizes in an image or a scanned document.
        ///   - handwritingText: The text that Notes recognizes in handwriting.
        ///   - table: The cells of a table.
        public init(
            id: ID,
            typeIdentifier: String? = nil,
            displayText: String? = nil,
            tokenIdentifier: String? = nil,
            title: String? = nil,
            url: URL? = nil,
            fileName: String? = nil,
            summary: String? = nil,
            recognizedText: String? = nil,
            handwritingText: String? = nil,
            table: Table? = nil
        ) {
            self.id = id
            self.typeIdentifier = typeIdentifier
            self.displayText = displayText
            self.tokenIdentifier = tokenIdentifier
            self.title = title
            self.url = url
            self.fileName = fileName
            self.summary = summary
            self.recognizedText = recognizedText
            self.handwritingText = handwritingText
            self.table = table
        }

        /// The kind of the attachment, from its type identifier.
        public var kind: Kind {
            Self.kind(of: typeIdentifier ?? "")
        }

        /// The identifier of the note that an inline link opens, if the attachment is one.
        public var linkedNoteID: Note.ID? {
            guard kind == .noteLink else { return nil }
            return tokenIdentifier.flatMap(noteID(inLink:))
        }

        /// Returns the kind of attachment that a type identifier names.
        static func kind(of type: String) -> Kind {
            if type.hasPrefix(inlineTypePrefix) {
                switch type.dropFirst(inlineTypePrefix.count) {
                case "hashtag": return .hashtag
                case "mention": return .mention
                case "link": return .noteLink
                case "calculateresult", "calculategraphexpression": return .calculation
                default: return .inlineText
                }
            }
            switch type {
            case tableType:
                return .table
            case "public.url":
                return .webLink
            case "com.apple.drawing", "com.apple.drawing.2", "com.apple.paper", "com.apple.notes.sketch":
                return .drawing
            case "com.apple.notes.gallery", "com.apple.paper.doc.scan", "com.apple.paper.doc.pdf":
                return .scannedDocument
            default:
                guard let uniformType = UTType(type) else { return .file }
                if uniformType.conforms(to: .image) { return .image }
                if uniformType.conforms(to: .pdf) { return .pdf }
                if uniformType.conforms(to: .audio) { return .audio }
                if uniformType.conforms(to: .movie) { return .video }
                if uniformType.conforms(to: .vCard) { return .contact }
                return .file
            }
        }
    }

    /// A table in a note.
    public struct Table: Sendable, Hashable {
        /// The cells, row by row from the top, each row from left to right as Notes shows it.
        ///
        /// Every row has the same number of cells.
        /// An empty cell has no paragraphs.
        /// In a right-to-left table, the table's first column is the last cell of each row.
        public let rows: [[Content]]
        /// A Boolean value that indicates whether the table's columns run from right to left.
        public let isRightToLeft: Bool

        /// Creates a table.
        /// - Parameters:
        ///   - rows: The cells, row by row from the top, each row from left to right.
        ///   - isRightToLeft: Whether the table's columns run from right to left.
        public init(rows: [[Content]], isRightToLeft: Bool = false) {
            self.rows = rows
            self.isRightToLeft = isRightToLeft
        }
    }
}
