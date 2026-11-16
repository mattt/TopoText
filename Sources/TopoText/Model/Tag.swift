import Foundation

extension Note {
    /// A tag in a note, such as `#groceries`.
    ///
    /// Notes stores a tag as an inline attachment in the note's text.
    /// ``Store/tags(for:)`` lists the tags of notes without decoding their contents.
    public struct Tag: Sendable, Hashable {
        /// The tag without its leading `#`, as it first appears in the note.
        public let name: String

        /// Creates a tag from the text that Notes stores, such as `#groceries`.
        ///
        /// Returns `nil` if nothing remains after the leading `#` characters and white space.
        public init?(_ text: String) {
            var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasPrefix("#") {
                name.removeFirst()
            }
            guard !name.isEmpty else { return nil }
            self.name = name
        }

        /// The tag with its leading `#`.
        public var text: String {
            "#" + name
        }

        /// The name that Notes compares: lowercased, without diacritics.
        var key: String {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
    }

    /// A link from one note to another.
    ///
    /// Notes stores the link as an inline attachment in the source note's text.
    /// The target note may no longer exist; check with ``Store/note(for:)``.
    public struct Link: Sendable, Hashable {
        /// The note that holds the link.
        public let sourceID: Note.ID
        /// The note that the link opens.
        public let targetID: Note.ID
        /// The text that Notes shows for the link, if any.
        public let label: String?

        /// Creates a link.
        /// - Parameters:
        ///   - sourceID: The note that holds the link.
        ///   - targetID: The note that the link opens.
        ///   - label: The text that Notes shows for the link, if any.
        public init(sourceID: Note.ID, targetID: Note.ID, label: String? = nil) {
            self.sourceID = sourceID
            self.targetID = targetID
            self.label = label
        }
    }
}

/// How many notes carry a tag.
public struct TagSummary: Sendable, Hashable {
    /// The tag, spelled as in the most recently edited note that has it.
    public let tag: Note.Tag
    /// The number of notes that have the tag.
    public let noteCount: Int

    /// Creates a summary.
    /// - Parameters:
    ///   - tag: The tag.
    ///   - noteCount: The number of notes that have the tag.
    public init(tag: Note.Tag, noteCount: Int) {
        self.tag = tag
        self.noteCount = noteCount
    }
}
