import Foundation

/// A change to the contents of a note.
///
/// The caller is expected to be a tool that a language model drives.
/// A model can't count UTF-16 code units, and the note can change between the read and the edit,
/// so an edit names a place by a paragraph or by a match of existing text.
/// A match by text alone that is absent or ambiguous fails; it does not land in another place.
/// That holds for ``ParagraphAnchor/containing(_:)`` and for a ``TextMatch`` without an occurrence.
/// An occurrence number, a paragraph index, an offset, and a range count in the text as it is when the edit applies,
/// so they name another place after text is inserted or deleted before them,
/// by another edit of the same call or by a change to the note since it was read.
///
/// Matches compare with the stored text, in which each attachment is one U+FFFC character.
/// The text of a tag or a mention is not in the stored text, so a match can't span one.
///
/// Pass edits to ``NoteEditor/edit(_:of:applying:)``.
///
/// Two edits are equal when they do the same thing.
/// Text to insert compares by its UTF-16 code units, because those are what the edit writes:
/// "é" as one character is another insertion than "e" with a combining accent.
/// Text to find compares as Swift strings do, by canonical equivalence, because a match finds either form.
public enum NoteEdit: Sendable {
    /// Inserts paragraphs at the end of the note, or before or after a paragraph.
    case insertParagraphs([NewParagraph], at: ParagraphPosition)
    /// Inserts text within a paragraph. The text can't contain a carriage return or a line feed.
    case insertText(String, at: TextPosition)
    /// Replaces text with other text. The new text can't contain a carriage return or a line feed.
    case replaceText(TextSelection, with: String)
    /// Deletes text.
    ///
    /// A paragraph keeps its style, and a checklist item its state, when its first characters are deleted,
    /// and the text that is left keeps its formatting.
    /// Deleting all of a paragraph's text leaves the paragraph, empty, with its style.
    /// To remove the paragraph, use ``deleteParagraphs(_:through:)``.
    case deleteText(TextSelection)
    /// Deletes whole paragraphs, from one paragraph through another, with their line feeds.
    case deleteParagraphs(ParagraphAnchor, through: ParagraphAnchor?)
    /// Sets whether a checklist item is done.
    case setChecked(Bool, at: ParagraphAnchor)

    /// Appends paragraphs to the end of the note.
    /// - Parameter paragraphs: The paragraphs, in order.
    /// - Returns: An edit that inserts the paragraphs at ``ParagraphPosition/end``.
    public static func appendParagraphs(_ paragraphs: [NewParagraph]) -> NoteEdit {
        .insertParagraphs(paragraphs, at: .end)
    }

    /// A paragraph to insert.
    ///
    /// Two paragraphs are equal when they have the same style and state, and their text has the same UTF-16 code units.
    public struct NewParagraph: Sendable {
        /// The style of a new paragraph.
        public enum Style: Hashable, Sendable {
            /// Body text.
            case body
            /// An item of a bulleted list.
            case bulleted
            /// An item of a numbered list.
            case numbered
            /// An item of a checklist.
            case checklist
        }

        /// The text. Each line feed in it starts another paragraph of the same style.
        ///
        /// A paragraph can be empty. The text can't have the character U+FFFC, which stands for an attachment.
        public let text: String
        /// The style of the paragraph.
        public let style: Style
        /// Whether a checklist item is done. Other styles ignore it.
        public let isChecked: Bool

        /// Creates a paragraph to insert.
        /// - Parameters:
        ///   - text: The text. Each line feed in it starts another paragraph of the same style.
        ///   - style: The style of the paragraph.
        ///   - isChecked: Whether a checklist item is done. Other styles ignore it.
        public init(_ text: String, style: Style = .body, isChecked: Bool = false) {
            self.text = text
            self.style = style
            self.isChecked = isChecked
        }
    }

    /// A paragraph of the note.
    public enum ParagraphAnchor: Hashable, Sendable {
        /// The paragraph at an index into ``Note/Content/paragraphs``, from 0.
        ///
        /// The index counts the paragraphs as they are when the edit applies.
        case index(Int)
        /// The one paragraph whose text contains the given text.
        ///
        /// The edit fails if no paragraph contains the text, or if more than one does.
        case containing(String)
    }

    /// A place for new paragraphs.
    public enum ParagraphPosition: Hashable, Sendable {
        /// The end of the note, after its last paragraph.
        case end
        /// Before a paragraph.
        case before(ParagraphAnchor)
        /// After a paragraph and its line feed.
        case after(ParagraphAnchor)
    }

    /// A match of existing text.
    ///
    /// The comparison is exact but for the composition of characters:
    /// a letter with an accent matches whether it is stored as one character or as two.
    /// Matches can overlap, and each one counts: "ana" matches twice in "banana".
    public struct TextMatch: Hashable, Sendable {
        /// The text to find. It is not empty.
        public let text: String
        /// The paragraph to search, or `nil` to search the note.
        public let paragraph: ParagraphAnchor?
        /// Which match to take, from 1, or `nil` if the text must match once.
        ///
        /// The number counts the matches in the text as it is when the edit applies.
        /// After another insertion of the same text, it names another match, and the edit does not fail.
        public let occurrence: Int?

        /// Creates a match of existing text.
        /// - Parameters:
        ///   - text: The text to find, which can't be empty.
        ///   - paragraph: The paragraph to search, or `nil` to search the note.
        ///   - occurrence: Which match to take, from 1, or `nil` if the text must match once.
        /// - Throws: ``NoteEditError/emptyMatchText`` if the text is empty,
        ///   or ``NoteEditError/invalidOccurrence(_:)`` if the occurrence is below 1.
        public init(_ text: String, in paragraph: ParagraphAnchor? = nil, occurrence: Int? = nil) throws {
            guard !text.isEmpty else {
                throw NoteEditError.emptyMatchText
            }
            if let occurrence, occurrence < 1 {
                throw NoteEditError.invalidOccurrence(occurrence)
            }
            self.text = text
            self.paragraph = paragraph
            self.occurrence = occurrence
        }
    }

    /// A place for new text.
    public enum TextPosition: Hashable, Sendable {
        /// Before the first character of a match.
        case before(TextMatch)
        /// After the last character of a match.
        case after(TextMatch)
        /// The start of a paragraph, before its first character.
        case startOfParagraph(ParagraphAnchor)
        /// The end of a paragraph, before its line feed.
        case endOfParagraph(ParagraphAnchor)
        /// An offset into the stored text, in UTF-16 code units.
        case offset(Int)
    }

    /// Existing text to replace or delete.
    public enum TextSelection: Hashable, Sendable {
        /// The text of a match.
        case match(TextMatch)
        /// The text of a paragraph, without its line feed.
        case paragraphText(ParagraphAnchor)
        /// A range of the stored text, in UTF-16 code units.
        case range(Range<Int>)
    }
}

extension NoteEdit.NewParagraph: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf16.elementsEqual(rhs.text.utf16) && lhs.style == rhs.style && lhs.isChecked == rhs.isChecked
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(text.utf16))
        hasher.combine(style)
        hasher.combine(isChecked)
    }
}

extension NoteEdit: Hashable {
    public static func == (lhs: NoteEdit, rhs: NoteEdit) -> Bool {
        switch (lhs, rhs) {
        case (.insertParagraphs(let paragraphs, let position), .insertParagraphs(let otherParagraphs, let otherPosition)):
            return paragraphs == otherParagraphs && position == otherPosition
        case (.insertText(let text, let position), .insertText(let otherText, let otherPosition)):
            return text.utf16.elementsEqual(otherText.utf16) && position == otherPosition
        case (.replaceText(let selection, let text), .replaceText(let otherSelection, let otherText)):
            return selection == otherSelection && text.utf16.elementsEqual(otherText.utf16)
        case (.deleteText(let selection), .deleteText(let otherSelection)):
            return selection == otherSelection
        case (.deleteParagraphs(let first, let last), .deleteParagraphs(let otherFirst, let otherLast)):
            return first == otherFirst && last == otherLast
        case (.setChecked(let isChecked, let anchor), .setChecked(let otherIsChecked, let otherAnchor)):
            return isChecked == otherIsChecked && anchor == otherAnchor
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .insertParagraphs(let paragraphs, let position):
            hasher.combine(0)
            hasher.combine(paragraphs)
            hasher.combine(position)
        case .insertText(let text, let position):
            hasher.combine(1)
            hasher.combine(Array(text.utf16))
            hasher.combine(position)
        case .replaceText(let selection, let text):
            hasher.combine(2)
            hasher.combine(selection)
            hasher.combine(Array(text.utf16))
        case .deleteText(let selection):
            hasher.combine(3)
            hasher.combine(selection)
        case .deleteParagraphs(let first, let last):
            hasher.combine(4)
            hasher.combine(first)
            hasher.combine(last)
        case .setChecked(let isChecked, let anchor):
            hasher.combine(5)
            hasher.combine(isChecked)
            hasher.combine(anchor)
        }
    }
}

/// The reason that an edit was not made.
///
/// An edit that fails changes nothing.
/// ``NoteEditor/edit(_:of:applying:)`` then returns no contents, whichever of its edits failed.
public enum NoteEditError: Error, Hashable, Sendable {
    /// The note is locked. Its contents are encrypted, and TopoText doesn't read or edit them.
    case noteLocked(Note.ID)
    /// The stored contents are not a note document that TopoText reads.
    case unreadableContent
    /// The stored document lacks a property that the edit engine relies on, so the engine leaves it alone.
    case unsupportedDocument(Invariant)
    /// No paragraph has the index, or contains the text.
    case paragraphNotFound(NoteEdit.ParagraphAnchor)
    /// More than one paragraph contains the text.
    case ambiguousParagraph(NoteEdit.ParagraphAnchor, matches: Int)
    /// The text of a match is empty. ``NoteEdit/TextMatch/init(_:in:occurrence:)`` throws this error.
    case emptyMatchText
    /// The occurrence of a match is below 1. ``NoteEdit/TextMatch/init(_:in:occurrence:)`` throws this error.
    case invalidOccurrence(Int)
    /// The note, or the paragraph that the match names, doesn't contain the text.
    case textNotFound(String)
    /// The text matches more than once, and the edit doesn't say which match to take.
    case ambiguousText(String, matches: Int)
    /// The text matches fewer times than the occurrence that the edit asks for.
    case occurrenceNotFound(String, matches: Int)
    /// The offset or range is outside the text.
    case outOfBounds
    /// The offset or range would split a surrogate pair, the two UTF-16 code units of one Unicode scalar.
    ///
    /// The editor doesn't check other boundaries within a character,
    /// such as the one between a letter and a combining accent.
    case splitsCharacter
    /// The range holds an attachment, which the edit would delete. The value is the attachment's type.
    case attachmentInRange(type: String?)
    /// The range holds a table, which the edit would delete.
    case tableInRange
    /// The position, or an end of the paragraph, is inside the run of an attachment, which the edit would split.
    case insideAttachment
    /// The paragraph holds a table, and text can't share a paragraph with a table.
    case tableInParagraph
    /// The paragraph holds an attachment whose run doesn't store its type.
    /// The type is in the attachment's row in the database, which the editor doesn't read,
    /// so the attachment can be a table, and text can't share a paragraph with a table.
    case untypedAttachmentInParagraph
    /// The range would join the start of one paragraph to the end of another, whose styles can differ.
    /// Delete whole paragraphs, or edit each paragraph separately.
    case joinsParagraphs
    /// The new text has a carriage return or a line feed. Insert paragraphs instead.
    case lineFeedInText
    /// The new text has the character U+FFFC, which stands for an attachment in stored text.
    case attachmentCharacterInText
    /// The paragraph is not a checklist item.
    case notChecklistItem
}

extension NoteEditError: LocalizedError {
    /// A sentence that says why the edit was not made, and what to do in its place where there is something to do.
    ///
    /// The description holds none of the note's text.
    public var errorDescription: String? {
        switch self {
        case .noteLocked:
            return "The note is locked, so it can't be edited."
        case .unreadableContent:
            return "The note's contents are not in a format that can be edited."
        case .unsupportedDocument(let invariant):
            return "The note can't be edited safely, because this is not true of its stored document: \(invariant.rawValue)."
        case .paragraphNotFound(.index(let index)):
            return "The note has no paragraph \(index)."
        case .paragraphNotFound(.containing):
            return "No paragraph contains the text."
        case .ambiguousParagraph(_, let matches):
            return "\(matches) paragraphs contain the text. Give more of the paragraph's text, or its index."
        case .emptyMatchText:
            return "The text to match is empty."
        case .invalidOccurrence(let occurrence):
            return "The occurrence \(occurrence) is not valid. Occurrences count from 1."
        case .textNotFound:
            return "The note doesn't contain the text to match. Text that spans a tag, a mention, or another attachment can't be matched."
        case .ambiguousText(_, let matches):
            return "The text matches \(matches) times. Give more text, a paragraph, or an occurrence."
        case .occurrenceNotFound(_, let matches):
            return "The text matches only \(matches) times."
        case .outOfBounds:
            return "The position is outside the note's text."
        case .splitsCharacter:
            return "The position is in the middle of a surrogate pair, the two code units of one character."
        case .attachmentInRange(let type):
            return "The edit would delete an attachment\(type.map { " of type \($0)" } ?? ""). Edit the text around it instead."
        case .tableInRange:
            return "The edit would delete a table. Edit the text around it instead."
        case .insideAttachment:
            return "The position or the paragraph's end is inside an attachment."
        case .tableInParagraph:
            return "The paragraph holds a table, and text can't be added next to a table. Insert a paragraph before or after it."
        case .untypedAttachmentInParagraph:
            return
                "The paragraph holds an attachment of an unknown type, which can be a table, and text can't be added next to a table. Insert a paragraph before or after it."
        case .joinsParagraphs:
            return "The edit would join parts of two paragraphs. Delete whole paragraphs, or edit each paragraph separately."
        case .lineFeedInText:
            return "The new text has a carriage return or a line feed. Insert paragraphs instead."
        case .attachmentCharacterInText:
            return "The new text has the character U+FFFC, which stands for an attachment."
        case .notChecklistItem:
            return "The paragraph is not a checklist item."
        }
    }
}

extension NoteEditError {
    /// A property of a stored document that the edit engine relies on.
    ///
    /// The engine checks every property before each edit and after the last one,
    /// and throws ``NoteEditError/unsupportedDocument(_:)`` with the first one that the document lacks.
    /// One run against a real database, which <doc:NoteStore> records, measured some of the properties and not others.
    /// Each of its 1,566 documents had the properties that existed then, the origin as its first substring,
    /// and a minimum supported version of 0.
    /// The run did not measure ``uniqueReplicas``, ``reachableSubstrings``, ``uniqueIdentifiers``,
    /// the replica and the length of the end marker, whether the end marker has children,
    /// or whether a character has the replica index 0.
    /// See <doc:NoteStore> also for the merge state that most of the properties describe.
    /// The raw value describes the property without any of the note's contents.
    public enum Invariant: String, CaseIterable, Hashable, Sendable {
        /// The document has one `Version` message, as Notes writes it.
        case oneVersion = "the document has one version"
        /// The `minimumSupportedVersion` of the version is 0 or absent. Another value asks for a reader of a later format.
        case supportedVersion = "the minimum supported version is 0"
        /// The stored text is valid UTF-8, so it can be read and written back without loss.
        case validText = "the text is valid UTF-8"
        /// The document has a vector timestamp, which lists the replicas that edited the note.
        case vectorTimestamp = "the document has a vector timestamp"
        /// Each replica of the vector timestamp has a UUID of 16 bytes.
        case replicaIdentifiers = "each replica has a 16-byte UUID"
        /// No two replicas of the vector timestamp have the same UUID.
        ///
        /// A character's identifier names its replica by position, so two entries with one UUID
        /// would let the editor give a clock value of one entry to a character when the other entry holds it already.
        case uniqueReplicas = "no two replicas have the same UUID"
        /// No replica clock has a `subclock`, which the engine does not maintain.
        case noSubclock = "no replica clock has a subclock"
        /// The first substring is the origin: it has the identifier (0, 0) and no characters.
        case originSubstring = "the first substring has the identifier (0, 0) and no characters"
        /// The last substring, and no other, is the end marker: it has the identifier (0, 0xFFFFFFFF) and no characters.
        case endSubstring = "the last substring, and no other, is the end marker, with the identifier (0, 0xFFFFFFFF) and no characters"
        /// The lengths of the substrings that hold text that is not deleted add up to the length of the text.
        case substringLengths = "the lengths of the substrings without a tombstone add up to the length of the text"
        /// The lengths of the attribute runs add up to the length of the text, and none is negative.
        case runLengths = "the lengths of the attribute runs add up to the length of the text, and none is negative"
        /// Each character identifier and style timestamp names a replica of the vector timestamp,
        /// and each substring that holds characters, deleted or not, names one by an index from 1.
        ///
        /// The index 0 belongs to the origin and the end marker, which hold no characters.
        case replicaIndexes =
            "each character identifier and style timestamp names a replica of the vector timestamp, and no character has the replica index 0"
        /// No substring holds a clock value past the text clock of its replica.
        case textClocks = "no substring has a clock value past its replica's text clock"
        /// Each clock is below 2 to the power 31.
        case clockRange = "each clock is below 2 to the power 31"
        /// Each tombstone, which marks deleted text, has the value 1.
        case tombstoneValues = "each tombstone value is 1"
        /// Each substring but the end marker has children, and each child comes later in the list of substrings.
        /// The end marker has none.
        case childIndexes = "each substring but the end marker has children, each child comes later in the list, and the end marker has none"
        /// The child indexes lead from the first substring to every other one.
        case reachableSubstrings = "each substring can be reached from the first along the child indexes"
        /// No two characters, deleted or not, have the same replica and clock value.
        case uniqueIdentifiers = "no two characters have one identifier"
    }
}
