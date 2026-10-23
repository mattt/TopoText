import Foundation

extension Note.Content {
    /// Returns the contents as Markdown.
    ///
    /// Each paragraph becomes a line of Markdown that matches its style:
    /// a title, heading, or subheading becomes a `#`, `##`, or `###` heading;
    /// a list item becomes a `-` or numbered item, indented four spaces for each level;
    /// a checklist item becomes `- [ ]` or `- [x]`;
    /// a block quote starts with `>`;
    /// and consecutive monospaced paragraphs become one fenced code block.
    /// Numbered lists count from ``Note/ParagraphStyle/startingNumber`` when Notes records one.
    /// A blank line separates blocks of different kinds, such as a list and the text after it,
    /// and surrounds each heading, code block, and table.
    /// A line separator (U+2028) breaks the line within its paragraph,
    /// except in a heading, which can't span lines, where it becomes a space.
    ///
    /// Bold, italic, and struck-through text and links become Markdown emphasis and links.
    /// Underlining, highlights, colors, superscript, subscript, and alignment
    /// have no Markdown form and are left out.
    /// Literal text is escaped, so that characters such as `*`, line starts such as `1.`,
    /// and text such as `&amp;` render as they appear in the note.
    /// Text in a code block isn't escaped, and its attachments become text as in ``plainText()``.
    /// A link's target keeps every character:
    /// spaces are percent-encoded, and characters such as parentheses are escaped.
    ///
    /// Each attachment becomes text:
    /// a tag, mention, or calculation result becomes the text that Notes shows;
    /// a link to another note or a link card becomes a Markdown link;
    /// a table becomes a Markdown table, with its first row as the header;
    /// and any other attachment becomes a description in brackets, such as `[Image: IMG_0001.jpeg]`.
    ///
    /// - Returns: The Markdown, with a line feed between lines.
    public func markdown() -> String {
        Renderer(format: .markdown).render(self)
    }

    /// Returns the text of the contents, without formatting.
    ///
    /// Each paragraph becomes a line,
    /// and a line separator (U+2028) becomes a line feed.
    /// Styles, list markers, checkboxes, and links are left out.
    /// Each attachment becomes text as in ``markdown()``, but without Markdown syntax:
    /// a link card becomes its title followed by its URL in parentheses,
    /// and a table becomes a line for each row, with a tab between cells.
    ///
    /// - Returns: The text, with a line feed between lines.
    public func plainText() -> String {
        Renderer(format: .plain).render(self)
    }
}
