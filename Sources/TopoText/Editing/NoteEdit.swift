import Foundation

/// A change to the contents of a note.
///
/// The caller is expected to be a tool that a language model drives.
/// A model can't count UTF-16 code units, and the note can change between the read and the edit,
/// so an edit names a place by a paragraph or by a match of existing text.
/// A match that is absent or ambiguous fails; it never lands in another place.
///
/// Matches compare with the stored text, in which each attachment is one U+FFFC character.
/// The text of a tag or a mention is not in the stored text, so a match can't span one.
enum NoteEdit: Hashable, Sendable {
    /// Inserts paragraphs at the end of the note, or before or after a paragraph.
    case insertParagraphs([NewParagraph], at: ParagraphPosition)
    /// Inserts text within a paragraph. The text can't contain a line feed.
    case insertText(String, at: TextPosition)
    /// Replaces text with other text. The new text can't contain a line feed.
    case replaceText(TextSelection, with: String)
    /// Deletes text.
    case deleteText(TextSelection)
    /// Deletes whole paragraphs, from one paragraph through another, with their line feeds.
    case deleteParagraphs(ParagraphAnchor, through: ParagraphAnchor?)
    /// Sets whether a checklist item is done.
    case setChecked(Bool, at: ParagraphAnchor)

    /// Appends paragraphs to the end of the note.
    static func appendParagraphs(_ paragraphs: [NewParagraph]) -> NoteEdit {
        .insertParagraphs(paragraphs, at: .end)
    }

    /// A paragraph to insert.
    struct NewParagraph: Hashable, Sendable {
        enum Style: Hashable, Sendable {
            case body
            case bulleted
            case numbered
            case checklist
        }

        /// The text. Each line feed in it starts another paragraph of the same style.
        var text: String
        var style: Style
        /// Whether a checklist item is done. Other styles ignore it.
        var isChecked: Bool

        init(_ text: String, style: Style = .body, isChecked: Bool = false) {
            self.text = text
            self.style = style
            self.isChecked = isChecked
        }
    }

    /// A paragraph of the note.
    enum ParagraphAnchor: Hashable, Sendable {
        /// The paragraph at an index into ``Note/Content/paragraphs``, from 0.
        case index(Int)
        /// The one paragraph whose text contains the given text.
        case containing(String)
    }

    /// A place for new paragraphs.
    enum ParagraphPosition: Hashable, Sendable {
        case end
        case before(ParagraphAnchor)
        case after(ParagraphAnchor)
    }

    /// A match of existing text.
    struct TextMatch: Hashable, Sendable {
        /// The text to find.
        var text: String
        /// The paragraph to search, or `nil` to search the note.
        var paragraph: ParagraphAnchor?
        /// Which match to take, from 1, or `nil` if the text must match once.
        var occurrence: Int?

        init(_ text: String, in paragraph: ParagraphAnchor? = nil, occurrence: Int? = nil) {
            self.text = text
            self.paragraph = paragraph
            self.occurrence = occurrence
        }
    }

    /// A place for new text.
    enum TextPosition: Hashable, Sendable {
        case before(TextMatch)
        case after(TextMatch)
        case startOfParagraph(ParagraphAnchor)
        /// The end of a paragraph, before its line feed.
        case endOfParagraph(ParagraphAnchor)
        /// An offset into the stored text, in UTF-16 code units.
        case offset(Int)
    }

    /// Existing text to replace or delete.
    enum TextSelection: Hashable, Sendable {
        case match(TextMatch)
        /// The text of a paragraph, without its line feed.
        case paragraphText(ParagraphAnchor)
        /// A range of the stored text, in UTF-16 code units.
        case range(Range<Int>)
    }
}

/// The reason that an edit was not made.
///
/// An edit that fails changes nothing.
enum NoteEditError: Error, Hashable, Sendable {
    /// The note is locked. Its contents are encrypted, and TopoText doesn't read or edit them.
    case noteLocked(Note.ID)
    /// The stored contents are not a note document that TopoText reads.
    case unreadableContent
    /// The stored document lacks a property that the edit engine relies on, so the engine leaves it alone.
    case unsupportedDocument(StoredNote.Invariant)
    /// No paragraph has the index, or contains the text.
    case paragraphNotFound(NoteEdit.ParagraphAnchor)
    /// More than one paragraph contains the text.
    case ambiguousParagraph(NoteEdit.ParagraphAnchor, matches: Int)
    /// The text to match is empty, or the note doesn't contain it.
    case textNotFound(String)
    /// The text matches more than once, and the edit doesn't say which match to take.
    case ambiguousText(String, matches: Int)
    /// The text matches fewer times than the occurrence that the edit asks for.
    case occurrenceNotFound(String, matches: Int)
    /// The offset or range is outside the text.
    case outOfBounds
    /// The offset or range would split a character that takes two UTF-16 code units.
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
    /// The new text has a line feed. Insert paragraphs instead.
    case lineFeedInText
    /// The new text has the character U+FFFC, which stands for an attachment in stored text.
    case attachmentCharacterInText
    /// The paragraph is not a checklist item.
    case notChecklistItem
}

extension NoteEditError: LocalizedError {
    var errorDescription: String? {
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
        case .textNotFound:
            return "The note doesn't contain the text to match. Text that spans a tag, a mention, or another attachment can't be matched."
        case .ambiguousText(_, let matches):
            return "The text matches \(matches) times. Give more text, a paragraph, or an occurrence."
        case .occurrenceNotFound(_, let matches):
            return "The text matches only \(matches) times."
        case .outOfBounds:
            return "The position is outside the note's text."
        case .splitsCharacter:
            return "The position is in the middle of a character."
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
            return "The new text has a line feed. Insert paragraphs instead."
        case .attachmentCharacterInText:
            return "The new text has the character U+FFFC, which stands for an attachment."
        case .notChecklistItem:
            return "The paragraph is not a checklist item."
        }
    }
}
