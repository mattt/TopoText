import Foundation
import TopoText

// Builders for contents that tests create directly, through the public API,
// instead of decoding them from a database.

/// Renders paragraphs as Markdown.
func markdown(_ paragraphs: [Note.Paragraph]) -> String {
    Note.Content(paragraphs: paragraphs).markdown()
}

/// Renders paragraphs as plain text.
func plainText(_ paragraphs: [Note.Paragraph]) -> String {
    Note.Content(paragraphs: paragraphs).plainText()
}

/// A paragraph with one run of text and the given style.
func paragraph(
    _ text: String,
    _ kind: Note.ParagraphStyle.Kind = .body,
    indent: Int = 0,
    isChecked: Bool = false,
    startingNumber: Int? = nil,
    isBlockQuote: Bool = false
) -> Note.Paragraph {
    Note.Paragraph(
        style: Note.ParagraphStyle(
            kind: kind,
            indent: indent,
            isChecked: isChecked,
            startingNumber: startingNumber,
            isBlockQuote: isBlockQuote
        ),
        runs: [Note.TextRun(text: text)]
    )
}

/// A paragraph with no text and the given style.
func emptyParagraph(_ kind: Note.ParagraphStyle.Kind = .body) -> Note.Paragraph {
    Note.Paragraph(style: Note.ParagraphStyle(kind: kind))
}

/// A table cell with a paragraph for each line, where an empty line is an empty paragraph.
func cell(_ lines: String...) -> Note.Content {
    Note.Content(paragraphs: lines.map { $0.isEmpty ? Note.Paragraph() : paragraph($0) })
}

/// A paragraph that holds only a table.
func tableParagraph(_ table: Note.Table) -> Note.Paragraph {
    Note.Paragraph(runs: [attachmentRun(type: "com.apple.notes.table", table: table)])
}

/// The type identifier of an inline attachment, such as `hashtag`.
func inlineType(_ name: String) -> String {
    "com.apple.notes.inlinetextattachment." + name
}

/// A run that stands for an attachment with the given values.
func attachmentRun(
    type: String,
    displayText: String? = nil,
    tokenIdentifier: String? = nil,
    title: String? = nil,
    url: URL? = nil,
    fileName: String? = nil,
    summary: String? = nil,
    table: Note.Table? = nil
) -> Note.TextRun {
    Note.TextRun(
        text: "\u{FFFC}",
        attachment: Note.Attachment(
            id: Note.Attachment.ID(UUID().uuidString)!,
            typeIdentifier: type,
            displayText: displayText,
            tokenIdentifier: tokenIdentifier,
            title: title,
            url: url,
            fileName: fileName,
            summary: summary,
            table: table
        )
    )
}
