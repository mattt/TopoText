import Foundation

extension Note.Content {
    /// The text that a search matches: the paragraphs, one per line,
    /// with the text of each attachment in place of its object replacement character.
    var searchableText: String {
        paragraphs.map { $0.runs.map(\.searchableText).joined() }.joined(separator: "\n")
    }
}

extension Note.TextRun {
    /// The text of the run, or of its attachment, with line separators as line feeds.
    var searchableText: String {
        guard let attachment else {
            return text.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n")
        }
        // Inline attachments read as part of the line; others stand on lines of their own.
        let text = attachment.searchableText
        return attachment.kind.isInline || text.isEmpty ? text : "\n\(text)\n"
    }
}

extension Note.Attachment {
    /// The text of an attachment that a search matches:
    /// the text of an inline attachment, the cells of a table, the title and URL of a link card,
    /// or the title and file name of another attachment,
    /// followed by any text that Notes recognizes in it.
    var searchableText: String {
        var parts: [String?]
        switch kind {
        case .hashtag, .mention, .noteLink, .calculation, .inlineText:
            parts = [displayText]
        case .table:
            let cells = table?.rows.map { $0.map(\.searchableText).joined(separator: "\t") }.joined(separator: "\n")
            parts = [cells ?? summary]
        case .webLink:
            parts = [title, url?.absoluteString]
        default:
            parts = [title, fileName]
        }
        parts += [recognizedText, handwritingText]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
