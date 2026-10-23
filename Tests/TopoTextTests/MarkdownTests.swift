import Foundation
import Testing
import TopoText

/// Tests ``Note/Content/markdown()`` with contents built through the public API.
@Suite struct MarkdownTests {
    // MARK: - Escaping

    @Test("Characters that Markdown reads as formatting are escaped")
    func escapesInlineCharacters() {
        #expect(
            markdown([paragraph("Use *stars*, _underscores_, `code`, [brackets], <tags>, and a~b")])
                == #"Use \*stars\*, \_underscores\_, \`code\`, \[brackets\], \<tags\>, and a\~b"#
        )
    }

    @Test("Backslashes are escaped")
    func escapesBackslashes() {
        #expect(markdown([paragraph(#"C:\Users"#)]) == #"C:\\Users"#)
    }

    @Test("Text that Markdown would read as a character reference is escaped")
    func escapesCharacterReferences() {
        #expect(
            markdown([paragraph("Tom &amp; Jerry &copy; &#169; &#xA9; & more, AT&T, &;, and &#;")])
                == #"Tom \&amp; Jerry \&copy; \&#169; \&#xA9; & more, AT&T, &;, and &#;"#
        )
    }

    @Test("Character references are escaped in cells and attachment text, but not in code")
    func escapesCharacterReferencesOutsideCode() {
        let tag = attachmentRun(type: inlineType("hashtag"), displayText: "#a&amp;b")
        #expect(markdown([Note.Paragraph(runs: [tag])]) == #"#a\&amp;b"#)
        #expect(markdown([tableParagraph(Note.Table(rows: [[cell("&lt;")]]))]) == #"| \&lt; |"# + "\n| --- |")
        #expect(markdown([paragraph("&amp;", .monospaced)]) == "```\n&amp;\n```")
        #expect(plainText([paragraph("&amp;")]) == "&amp;")
    }

    @Test("Pipes and hashes within a line are left as they are")
    func leavesPipesAndHashesWithinLines() {
        #expect(markdown([paragraph("a | b # c")]) == "a | b # c")
    }

    @Test("Markers at the start of a line are escaped")
    func escapesMarkersAtLineStart() {
        let lines = [
            "# Groceries", "###### Six", "+ milk", "- eggs", "1. bread", "2) butter", "2024. was a year",
            "---", "===", "  # indented",
        ]
        #expect(
            markdown(lines.map { paragraph($0) })
                == [
                    ##"\# Groceries"##, "\\###### Six", #"\+ milk"#, #"\- eggs"#, #"1\. bread"#, #"2\) butter"#,
                    #"2024\. was a year"#, #"\---"#, #"\==="#, ##"  \# indented"##,
                ].joined(separator: "\n")
        )
    }

    @Test("Markers alone on a line, after tabs, and with several digits are escaped")
    func escapesOtherMarkerForms() {
        let lines = ["10. ten", "+", "#", "1)", "\t- tab", "  1. two spaces"]
        #expect(
            markdown(lines.map { paragraph($0) })
                == [#"10\. ten"#, #"\+"#, ##"\#"##, #"1\)"#, "\t\\- tab", #"  1\. two spaces"#].joined(separator: "\n")
        )
    }

    @Test("Text that only resembles a marker is left as it is")
    func leavesTextThatOnlyResemblesMarkers() {
        let lines = ["#hashtag", "####### seven", "-5 degrees", "1.5 cups", "1234567890. too long", "--- and more"]
        #expect(markdown(lines.map { paragraph($0) }) == lines.joined(separator: "\n"))
    }

    @Test("Markers after a line separator are escaped")
    func escapesLineStartAfterLineSeparator() {
        #expect(
            markdown([paragraph("Intro\u{2028}# not a heading\u{2028}- not an item")])
                == "Intro\n\\# not a heading\n\\- not an item"
        )
    }

    // MARK: - Inline formatting

    @Test("Runs are formatted, with spaces outside the markers")
    func formatsRunsAndKeepsSpacesOutsideMarkers() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "Plain "),
            Note.TextRun(text: "bold ", isBold: true),
            Note.TextRun(text: "italic", isItalic: true),
            Note.TextRun(text: " "),
            Note.TextRun(text: "both", isBold: true, isItalic: true),
            Note.TextRun(text: " "),
            Note.TextRun(text: "gone", isStrikethrough: true),
            Note.TextRun(text: " "),
            Note.TextRun(text: "under", isUnderlined: true),
            Note.TextRun(text: " "),
            Note.TextRun(text: "site", link: "https://example.com"),
        ])
        #expect(markdown([paragraph]) == "Plain **bold** *italic* ***both*** ~~gone~~ under [site](https://example.com)")
    }

    @Test("Neighboring runs with the same formatting share one pair of markers")
    func mergesNeighboringRuns() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "Hel", isBold: true),
            Note.TextRun(text: "lo", isBold: true),
        ])
        #expect(markdown([paragraph]) == "**Hello**")
    }

    @Test("Runs with different links stay separate links")
    func keepsDifferentLinksApart() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "a", link: "https://a.example"),
            Note.TextRun(text: "b", link: "https://b.example"),
        ])
        #expect(markdown([paragraph]) == "[a](https://a.example)[b](https://b.example)")
    }

    @Test("Link targets keep every character as the link's destination")
    func escapesLinkDestinations() {
        let targets = [
            "https://example.com/a)b",
            "https://en.wikipedia.org/wiki/Swift_(programming_language)",
            "https://example.com/a b",
            "https://example.com/?q=<x>&copy;&a=1&b=2",
            #"C:\Notes\file"#,
        ]
        #expect(
            markdown(targets.map { Note.Paragraph(runs: [Note.TextRun(text: "x", link: $0)]) })
                == [
                    #"[x](https://example.com/a\)b)"#,
                    #"[x](https://en.wikipedia.org/wiki/Swift_\(programming_language\))"#,
                    "[x](https://example.com/a%20b)",
                    #"[x](https://example.com/?q=\<x\>\&copy;&a=1&b=2)"#,
                    #"[x](C:\\Notes\\file)"#,
                ].joined(separator: "\n")
        )
    }

    @Test("Link cards and links to notes format their targets the same way")
    func escapesAttachmentLinkDestinations() {
        let card = attachmentRun(type: "public.url", title: "Card", url: URL(string: "https://example.com/a%29b(c"))
        let noteLink = attachmentRun(type: inlineType("link"), displayText: "Note", tokenIdentifier: "applenotes:note/A B)")
        #expect(markdown([Note.Paragraph(runs: [card])]) == #"[Card](https://example.com/a%29b\(c)"#)
        #expect(markdown([Note.Paragraph(runs: [noteLink])]) == #"[Note](applenotes:note/A%20B\))"#)
    }

    @Test("Formatted text is escaped inside its markers")
    func escapesFormattedText() {
        #expect(markdown([Note.Paragraph(runs: [Note.TextRun(text: "a*b", isBold: true)])]) == #"**a\*b**"#)
    }

    @Test("Formatting combines, with links outermost")
    func combinesFormatting() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "site", isBold: true, link: "https://example.com"),
            Note.TextRun(text: " "),
            Note.TextRun(text: "gone", isBold: true, isStrikethrough: true),
        ])
        #expect(markdown([paragraph]) == "[**site**](https://example.com) **~~gone~~**")
    }

    @Test("Formatting on spaces alone adds no markers")
    func leavesFormattedSpacesBare() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "a"),
            Note.TextRun(text: " ", isBold: true),
            Note.TextRun(text: "b"),
        ])
        #expect(markdown([paragraph]) == "a b")
    }

    @Test("Tabs at the edges of a run stay outside its markers")
    func keepsTabsOutsideMarkers() {
        #expect(markdown([Note.Paragraph(runs: [Note.TextRun(text: "\tx\t", isItalic: true)])]) == "\t*x*\t")
    }

    @Test("Nonbreaking and other Unicode spaces at the edges of a run stay outside its markers")
    func keepsUnicodeSpacesOutsideMarkers() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "10\u{00A0}", isBold: true),
            Note.TextRun(text: "kg and"),
            Note.TextRun(text: "\u{2003}wide", isItalic: true),
        ])
        #expect(markdown([paragraph]) == "**10**\u{00A0}kg and\u{2003}*wide*")
    }

    @Test("Mixed spaces at the end of a run keep their order")
    func keepsOrderOfTrailingSpaces() {
        #expect(markdown([Note.Paragraph(runs: [Note.TextRun(text: "x \t", isItalic: true)])]) == "*x* \t")
    }

    @Test("A line separator at the edge of a run stays outside its markers")
    func keepsLineSeparatorsOutsideMarkers() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "bold\u{2028}", isBold: true),
            Note.TextRun(text: "next"),
        ])
        #expect(markdown([paragraph]) == "**bold**\nnext")
    }

    @Test("Formatting without a Markdown form is left out")
    func dropsFormattingWithoutMarkdownForm() {
        let run = Note.TextRun(
            text: "x",
            isUnderlined: true,
            baselinePosition: .superscript,
            highlight: .mint,
            color: Note.TextRun.Color(red: 1, green: 0, blue: 0)
        )
        #expect(markdown([Note.Paragraph(runs: [run])]) == "x")
    }

    // MARK: - Headings and paragraphs

    @Test("Headings have blank lines around them")
    func rendersHeadings() {
        let content = [
            paragraph("My Note", .title),
            paragraph("Intro"),
            paragraph("Section", .heading),
            paragraph("Part", .subheading),
            paragraph("Body"),
        ]
        #expect(markdown(content) == "# My Note\n\nIntro\n\n## Section\n\n### Part\n\nBody")
    }

    @Test("The lines of a heading join with spaces")
    func joinsHeadingLines() {
        #expect(markdown([paragraph("Two\u{2028}lines", .heading)]) == "## Two lines")
    }

    @Test("Consecutive body paragraphs are separate lines")
    func separatesBodyParagraphsByLine() {
        #expect(markdown([paragraph("a"), paragraph("b")]) == "a\nb")
    }

    @Test("Empty paragraphs are blank lines")
    func keepsEmptyParagraphs() {
        #expect(markdown([paragraph("a"), Note.Paragraph(), paragraph("b")]) == "a\n\nb")
    }

    @Test("An empty heading is a blank line")
    func rendersEmptyHeadingsAsBlankLines() {
        #expect(markdown([paragraph("A"), paragraph("", .heading), paragraph("B")]) == "A\n\nB")
    }

    @Test("A blank line in the note isn't doubled where blocks change")
    func doesNotDoubleBlankLines() {
        #expect(markdown([paragraph("H", .heading), emptyParagraph(), paragraph("b")]) == "## H\n\nb")
    }

    @Test("Indented body text isn't indented, so it doesn't become a code block")
    func ignoresIndentOfBodyText() {
        let paragraph = Note.Paragraph(style: Note.ParagraphStyle(indent: 2), runs: [Note.TextRun(text: "a")])
        #expect(markdown([paragraph]) == "a")
    }

    @Test("Empty contents render as an empty string")
    func rendersEmptyContents() {
        #expect(Note.Content().markdown() == "")
    }

    // MARK: - Lists

    @Test("Numbered lists count up and continue past nested items")
    func numbersListsPastNestedItems() {
        let content = [
            paragraph("a", .numberedList),
            paragraph("b", .numberedList),
            paragraph("c", .bulletedList, indent: 1),
            paragraph("d", .numberedList),
        ]
        #expect(markdown(content) == "1. a\n2. b\n    - c\n3. d")
    }

    @Test("Nested numbered lists count on their own")
    func numbersNestedListsSeparately() {
        let content = [
            paragraph("a", .numberedList),
            paragraph("x", .numberedList, indent: 1),
            paragraph("y", .numberedList, indent: 1),
            paragraph("b", .numberedList),
            paragraph("z", .numberedList, indent: 1),
        ]
        #expect(markdown(content) == "1. a\n    1. x\n    2. y\n2. b\n    1. z")
    }

    @Test("Numbering restarts after a paragraph that isn't a list item")
    func restartsNumberingAfterOtherBlocks() {
        let content = [
            paragraph("a", .numberedList),
            paragraph("b", .numberedList),
            paragraph("Between"),
            paragraph("c", .numberedList),
        ]
        #expect(markdown(content) == "1. a\n2. b\n\nBetween\n\n1. c")
    }

    @Test("Numbering restarts after an empty paragraph")
    func restartsNumberingAfterEmptyParagraphs() {
        #expect(markdown([paragraph("a", .numberedList), emptyParagraph(), paragraph("b", .numberedList)]) == "1. a\n\n1. b")
    }

    @Test("Numbering restarts after a code block")
    func restartsNumberingAfterCodeBlocks() {
        let content = [
            paragraph("a", .numberedList),
            paragraph("x", .monospaced),
            paragraph("b", .numberedList),
        ]
        #expect(markdown(content) == "1. a\n\n```\nx\n```\n\n1. b")
    }

    @Test("Numbering restarts after a list item of another kind at the same level")
    func restartsNumberingAfterOtherListKinds() {
        let content = [
            paragraph("a", .numberedList),
            paragraph("b", .numberedList),
            paragraph("c", .checklist),
            paragraph("d", .numberedList),
        ]
        #expect(markdown(content) == "1. a\n2. b\n- [ ] c\n1. d")
    }

    @Test("A numbered list starts at its starting number")
    func startsAtStartingNumber() {
        let content = [
            paragraph("e", .numberedList, startingNumber: 5),
            paragraph("f", .numberedList, startingNumber: 5),
        ]
        #expect(markdown(content) == "5. e\n6. f")
    }

    @Test("Bulleted and dashed lists use dashes")
    func rendersBulletedAndDashedLists() {
        #expect(markdown([paragraph("bullet", .bulletedList), paragraph("dash", .dashedList)]) == "- bullet\n- dash")
    }

    @Test("Each level of a list indents four spaces")
    func indentsNestedLists() {
        let content = [
            paragraph("a", .bulletedList),
            paragraph("b", .bulletedList, indent: 1),
            paragraph("c", .bulletedList, indent: 2),
        ]
        #expect(markdown(content) == "- a\n    - b\n        - c")
    }

    @Test("The lines of a list item line up with its text")
    func alignsContinuationLines() {
        let content = [
            paragraph("one\u{2028}two", .numberedList),
            paragraph("three\u{2028}four", .bulletedList, indent: 1),
        ]
        #expect(markdown(content) == "1. one\n   two\n    - three\n      four")
    }

    @Test("Empty list items are bare markers")
    func rendersEmptyListItems() {
        #expect(markdown([emptyParagraph(.numberedList), emptyParagraph(.bulletedList)]) == "1.\n-")
    }

    @Test("A blank line separates a list from the text around it")
    func separatesListsFromText() {
        #expect(markdown([paragraph("a", .bulletedList), paragraph("b")]) == "- a\n\nb")
        #expect(markdown([paragraph("a"), paragraph("b", .bulletedList)]) == "a\n\n- b")
    }

    @Test("Markers at the start of a list item's text are escaped")
    func escapesMarkersInListItems() {
        #expect(markdown([paragraph("- dash", .bulletedList)]) == #"- \- dash"#)
    }

    @Test("Checklist items show whether they are checked")
    func rendersChecklists() {
        let content = [
            paragraph("milk", .checklist),
            paragraph("eggs", .checklist, isChecked: true),
            emptyParagraph(.checklist),
        ]
        #expect(markdown(content) == "- [ ] milk\n- [x] eggs\n- [ ]")
    }

    // MARK: - Code

    @Test("Consecutive monospaced paragraphs are one code block")
    func rendersMonospacedParagraphsAsOneCodeBlock() {
        let content = [
            paragraph("Intro"),
            paragraph("let a = b * c_d", .monospaced),
            paragraph("print(a)\u{2028}// done", .monospaced),
            paragraph("After"),
        ]
        #expect(markdown(content) == "Intro\n\n```\nlet a = b * c_d\nprint(a)\n// done\n```\n\nAfter")
    }

    @Test("A code fence is longer than any run of backticks in the code")
    func lengthensFence() {
        #expect(markdown([paragraph("``` and ``", .monospaced)]) == "````\n``` and ``\n````")
        #expect(markdown([paragraph("`` only", .monospaced)]) == "```\n`` only\n```")
    }

    @Test("Attachment text in code isn't escaped")
    func leavesAttachmentTextUnescapedInCode() {
        let paragraph = Note.Paragraph(
            style: Note.ParagraphStyle(kind: .monospaced),
            runs: [
                Note.TextRun(text: "tag: "),
                attachmentRun(type: inlineType("hashtag"), displayText: "#to_do"),
            ]
        )
        #expect(markdown([paragraph]) == "```\ntag: #to_do\n```")
    }

    @Test("Formatting in code is left out")
    func dropsFormattingInCode() {
        let paragraph = Note.Paragraph(
            style: Note.ParagraphStyle(kind: .monospaced),
            runs: [Note.TextRun(text: "bold", isBold: true), Note.TextRun(text: " *x*")]
        )
        #expect(markdown([paragraph]) == "```\nbold *x*\n```")
    }

    @Test("A code block has a blank line after it, and none is added after a blank line")
    func separatesCodeBlocks() {
        #expect(markdown([paragraph("x", .monospaced), paragraph("H", .heading)]) == "```\nx\n```\n\n## H")
        #expect(markdown([paragraph("a"), emptyParagraph(), paragraph("x", .monospaced)]) == "a\n\n```\nx\n```")
    }

    // MARK: - Block quotes

    @Test("Block quotes mark each line")
    func rendersBlockQuotes() {
        let content = [
            paragraph("Intro"),
            paragraph("first\u{2028}second", isBlockQuote: true),
            paragraph("third", isBlockQuote: true),
        ]
        #expect(markdown(content) == "Intro\n\n> first\n> second\n> third")
    }

    @Test("Quoted list items keep their lines within the quote and the item")
    func quotesListItems() {
        #expect(markdown([paragraph("a\u{2028}b", .bulletedList, isBlockQuote: true)]) == "> - a\n>   b")
    }

    @Test("A quoted heading joins its lines with spaces")
    func quotesHeadings() {
        #expect(markdown([paragraph("Two\u{2028}lines", .heading, isBlockQuote: true)]) == "> ## Two lines")
    }

    @Test("Markers at the start of quoted text are escaped")
    func escapesMarkersInQuotes() {
        #expect(markdown([paragraph("# not", isBlockQuote: true)]) == ##"> \# not"##)
    }

    @Test("A blank line separates a quote from the text after it")
    func separatesQuotesFromText() {
        #expect(markdown([paragraph("q", isBlockQuote: true), paragraph("b")]) == "> q\n\nb")
    }

    // MARK: - Tables

    @Test("Tables have a header row, with cells escaped and their lines joined")
    func rendersTables() {
        let table = Note.Table(rows: [
            [cell("Name"), cell("Qty")],
            [cell("a|b"), cell("line1", "line2")],
            [cell("*x*"), cell("trailing", "")],
        ])
        #expect(
            markdown([paragraph("Intro"), tableParagraph(table), paragraph("After")]) == """
                Intro

                | Name | Qty |
                | --- | --- |
                | a\\|b | line1<br>line2 |
                | \\*x\\* | trailing |

                After
                """
        )
    }

    @Test("Backslashes in cells are escaped")
    func escapesBackslashesInCells() {
        #expect(markdown([tableParagraph(Note.Table(rows: [[cell(#"a\b"#)]]))]) == #"| a\\b |"# + "\n| --- |")
    }

    @Test("Formatting and links in cells are left out")
    func dropsFormattingInCells() {
        let formatted = Note.Content(paragraphs: [
            Note.Paragraph(runs: [Note.TextRun(text: "x", isBold: true, link: "https://example.com")])
        ])
        #expect(markdown([tableParagraph(Note.Table(rows: [[cell("Name")], [formatted]]))]) == "| Name |\n| --- |\n| x |")
    }

    @Test("Consecutive tables have a blank line between them")
    func separatesTables() {
        let first = Note.Table(rows: [[cell("A")]])
        let second = Note.Table(rows: [[cell("B")]])
        #expect(markdown([tableParagraph(first), tableParagraph(second)]) == "| A |\n| --- |\n\n| B |\n| --- |")
    }

    @Test("A table without cells renders nothing")
    func rendersEmptyTablesAsNothing() {
        #expect(markdown([tableParagraph(Note.Table(rows: []))]) == "")
        #expect(markdown([tableParagraph(Note.Table(rows: [[]]))]) == "")
    }

    @Test("A table that wasn't decoded shows its summary, or a description")
    func fallsBackToTableSummary() {
        let summarized = attachmentRun(type: "com.apple.notes.table", summary: "Name Qty")
        let bare = attachmentRun(type: "com.apple.notes.table")
        #expect(markdown([Note.Paragraph(runs: [summarized])]) == "Name Qty")
        #expect(markdown([Note.Paragraph(runs: [bare])]) == "[Table]")
    }

    // MARK: - Links and attachments

    @Test("Link cards are links, titled when they have a title")
    func rendersWebLinks() {
        let titled = attachmentRun(type: "public.url", title: "Example [site]", url: URL(string: "https://example.com"))
        let untitled = attachmentRun(type: "public.url", url: URL(string: "https://example.com"))
        #expect(
            markdown([Note.Paragraph(runs: [Note.TextRun(text: "See "), titled, Note.TextRun(text: " now")])])
                == #"See [Example \[site\]](https://example.com) now"#
        )
        #expect(markdown([Note.Paragraph(runs: [untitled])]) == "[https://example.com](https://example.com)")
    }

    @Test("A link card without a URL is described as an attachment")
    func describesWebLinksWithoutURLs() {
        #expect(markdown([Note.Paragraph(runs: [attachmentRun(type: "public.url", title: "Title")])]) == "[Attachment: Title]")
    }

    @Test("Inline attachments show their text, and links to notes are links")
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
        #expect(markdown([paragraph]) == #"#to\_do @Ann [Other note](applenotes:note/ABC) = 42"#)
    }

    @Test("A link to a note without a target shows its text")
    func rendersNoteLinksWithoutTargets() {
        #expect(markdown([Note.Paragraph(runs: [attachmentRun(type: inlineType("link"), displayText: "Other_note")])]) == #"Other\_note"#)
    }

    @Test("Inline attachments of unknown kinds show their text, and those without text show nothing")
    func rendersOtherInlineAttachments() {
        let paragraph = Note.Paragraph(runs: [
            Note.TextRun(text: "a"),
            attachmentRun(type: inlineType("hashtag")),
            attachmentRun(type: inlineType("future"), displayText: "x"),
            Note.TextRun(text: "b"),
        ])
        #expect(markdown([paragraph]) == "axb")
    }

    @Test("Other attachments are described in brackets, with their names")
    func describesMediaAttachments() {
        let runs = [
            attachmentRun(type: "public.jpeg", fileName: "photo_1.jpg"),
            attachmentRun(type: "com.apple.drawing.2"),
            attachmentRun(type: "com.apple.paper.doc.scan", title: "Receipt"),
            attachmentRun(type: "com.adobe.pdf", title: "Manual"),
            attachmentRun(type: "public.mp3"),
            attachmentRun(type: "public.mpeg-4"),
            attachmentRun(type: "public.vcard"),
            attachmentRun(type: "public.data", fileName: "notes.bin"),
        ]
        #expect(
            markdown(runs.map { Note.Paragraph(runs: [$0]) })
                == [
                    #"[Image: photo\_1.jpg]"#, "[Drawing]", "[Scanned document: Receipt]", "[PDF: Manual]",
                    "[Audio]", "[Video]", "[Contact]", "[Attachment: notes.bin]",
                ].joined(separator: "\n")
        )
    }

    @Test("An attachment without a type is described as an attachment")
    func describesUntypedAttachments() {
        let run = Note.TextRun(text: "\u{FFFC}", attachment: Note.Attachment(id: Note.Attachment.ID("A")!))
        #expect(markdown([Note.Paragraph(runs: [run])]) == "[Attachment]")
    }

    @Test("Object replacement characters outside attachments are left out")
    func dropsStrayObjectReplacementCharacters() {
        #expect(markdown([paragraph("a\u{FFFC}b")]) == "ab")
    }
}
