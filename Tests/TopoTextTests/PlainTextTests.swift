import Foundation
import Testing
import TopoText

/// Tests ``Note/Content/plainText()`` with contents built through the public API.
@Suite struct PlainTextTests {
    @Test("Styles, markers, and escapes are left out")
    func leavesOutMarkup() {
        let content = [
            paragraph("Title", .title),
            paragraph("*literal*"),
            paragraph("item", .numberedList),
            paragraph("done", .checklist, isChecked: true),
            paragraph("let x = 1", .monospaced),
            paragraph("a\u{2028}b", isBlockQuote: true),
        ]
        #expect(plainText(content) == "Title\n*literal*\nitem\ndone\nlet x = 1\na\nb")
    }

    @Test("Formatting and link targets are left out")
    func leavesOutFormattingAndLinks() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "bold", isBold: true),
            Note.TextRun(text: " "),
            Note.TextRun(text: "site", link: "https://example.com"),
        ])
        #expect(plainText([paragraph]) == "bold site")
    }

    @Test("Empty paragraphs are empty lines")
    func keepsEmptyParagraphs() {
        #expect(plainText([paragraph("a"), Note.Paragraph(), paragraph("b")]) == "a\n\nb")
    }

    @Test("Empty contents render as an empty string")
    func rendersEmptyContents() {
        #expect(Note.Content().plainText() == "")
    }

    @Test("Tables are rows of cells separated by tabs")
    func rendersTables() {
        let table = Note.Table(rows: [
            [cell("Name"), cell("Qty")],
            [cell("*x*"), cell("2")],
        ])
        #expect(plainText([tableParagraph(table)]) == "Name\tQty\n*x*\t2")
    }

    @Test("A table that wasn't decoded shows its summary, or a description")
    func fallsBackToTableSummary() {
        #expect(plainText([Note.Paragraph(runs: [attachmentRun(type: "com.apple.notes.table", summary: "Name Qty")])]) == "Name Qty")
        #expect(plainText([Note.Paragraph(runs: [attachmentRun(type: "com.apple.notes.table")])]) == "[Table]")
    }

    @Test("Link cards show their titles and URLs")
    func rendersWebLinks() {
        let titled = attachmentRun(type: "public.url", title: "Example [site]", url: URL(string: "https://example.com"))
        let untitled = attachmentRun(type: "public.url", url: URL(string: "https://example.com"))
        #expect(
            plainText([Note.Paragraph(runs: [Note.TextRun(text: "See "), titled, Note.TextRun(text: " now")])])
                == "See Example [site] (https://example.com) now"
        )
        #expect(plainText([Note.Paragraph(runs: [untitled])]) == "https://example.com")
    }

    @Test("Inline attachments show their text, without link targets")
    func rendersInlineAttachments() {
        let paragraph = Note.Paragraph(runs: [
            attachmentRun(type: inlineType("hashtag"), displayText: "#to_do"),
            Note.TextRun(text: " "),
            attachmentRun(type: inlineType("mention"), displayText: "@Ann"),
            Note.TextRun(text: " "),
            attachmentRun(type: inlineType("link"), displayText: "Other note", tokenIdentifier: "applenotes:note/ABC"),
            Note.TextRun(text: " = "),
            attachmentRun(type: inlineType("calculateresult"), displayText: "42"),
        ])
        #expect(plainText([paragraph]) == "#to_do @Ann Other note = 42")
    }

    @Test("Other attachments are described in brackets, without escapes")
    func describesMediaAttachments() {
        #expect(plainText([Note.Paragraph(runs: [attachmentRun(type: "public.jpeg", fileName: "photo_1.jpg")])]) == "[Image: photo_1.jpg]")
    }

    @Test("Object replacement characters outside attachments are left out")
    func dropsStrayObjectReplacementCharacters() {
        #expect(plainText([paragraph("a\u{FFFC}b")]) == "ab")
    }
}
