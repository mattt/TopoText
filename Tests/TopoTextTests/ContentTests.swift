@testable import TopoText
import Foundation
import Testing

/// Decodes runs into contents, with attachment rows from a dictionary instead of a database.
func content(_ runs: [RunSpec], rows: [Note.Attachment.ID: Database.AttachmentRow] = [:]) throws -> Note.Content {
    try content(of: noteMessage(runs), rows: rows)
}

/// Decodes a `Note` message into contents, with attachment rows from a dictionary.
func content(of message: PB, rows: [Note.Attachment.ID: Database.AttachmentRow] = [:]) throws -> Note.Content {
    var resolver = AttachmentResolver { identifiers in rows.filter { identifiers.contains($0.key) } }
    return try resolver.content(of: NoteDocument(ProtobufMessage(Data(message.data))))
}

@Suite struct ContentTests {
    @Test("The run that covers a paragraph's first character sets its style")
    func paragraphStyleFromFirstCharacter() throws {
        let paragraphs = try content([
            RunSpec(text: "Start\n"),
            RunSpec(text: "Three", style: 102, start: 3),
            RunSpec(text: "\n"),
            RunSpec(text: "\n", style: 103, checked: false),
            RunSpec(text: "Body", style: 1),
            RunSpec(text: " text\n", style: 103),
        ]).paragraphs

        #expect(paragraphs.map(\.text) == ["Start", "Three", "", "Body text"])
        #expect(paragraphs.map(\.style.kind) == [.body, .numberedList, .checklist, .heading])
        #expect(paragraphs[1].style.startingNumber == 3)
        // An empty paragraph's first character is its line feed.
        #expect(paragraphs[2].runs.isEmpty)
    }

    @Test("Line separators stay within a paragraph")
    func lineSeparators() throws {
        let paragraphs = try content([RunSpec(text: "Line one\u{2028}line two\nNext")]).paragraphs
        #expect(paragraphs.map(\.text) == ["Line one\u{2028}line two", "Next"])
    }

    @Test("Paragraph styles carry indent, checked state, block quotes, and alignment")
    func paragraphStyles() throws {
        let paragraphs = try content([
            RunSpec(text: "Done\n", style: 103, indent: 2, checked: true),
            RunSpec(text: "Quoted\n", quote: true, alignment: 1),
            RunSpec(text: "Code\n", style: 4, alignment: 3),
            RunSpec(text: "Unknown\n", style: 99, alignment: 9),
        ]).paragraphs

        #expect(paragraphs[0].style == Note.ParagraphStyle(kind: .checklist, indent: 2, isChecked: true))
        #expect(paragraphs[1].style == Note.ParagraphStyle(isBlockQuote: true, alignment: .center))
        #expect(paragraphs[2].style == Note.ParagraphStyle(kind: .monospaced, alignment: .justified))
        #expect(paragraphs[3].style == Note.ParagraphStyle())
    }

    @Test("Runs carry their formatting")
    func runFormatting() throws {
        let runs = try content([
            RunSpec(text: "bold", weight: 1),
            RunSpec(text: "italic", weight: 2),
            RunSpec(text: "both", weight: 3, underline: true),
            RunSpec(text: "struck", strike: true),
            RunSpec(text: "up", superscript: 1),
            RunSpec(text: "down", superscript: -1),
            RunSpec(text: "link", link: "https://example.com"),
            RunSpec(text: "red", color: (1, 0, 0, 1)),
            RunSpec(text: "mint", highlight: 4),
            RunSpec(text: "odd", highlight: 42),
        ]).paragraphs[0].runs

        #expect(runs.map(\.text) == ["bold", "italic", "both", "struck", "up", "down", "link", "red", "mint", "odd"])
        #expect(runs[0] == Note.TextRun(text: "bold", isBold: true))
        #expect(runs[1] == Note.TextRun(text: "italic", isItalic: true))
        #expect(runs[2] == Note.TextRun(text: "both", isBold: true, isItalic: true, isUnderlined: true))
        #expect(runs[3] == Note.TextRun(text: "struck", isStrikethrough: true))
        #expect(runs[4].baselinePosition == .superscript)
        #expect(runs[5].baselinePosition == .subscript)
        #expect(runs[6].link == "https://example.com")
        #expect(runs[7].color == Note.TextRun.Color(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(runs[8].highlight == .mint)
        #expect(runs[9].highlight == nil)
        #expect(runs[9] == Note.TextRun(text: "odd"))
    }

    @Test("Run lengths count UTF-16 code units")
    func utf16Lengths() throws {
        let runs = try content([
            RunSpec(text: "😀 ", weight: 1),
            RunSpec(text: "é"),
            RunSpec(text: "👩‍👩‍👧", weight: 2),
        ]).paragraphs[0].runs
        #expect(runs.map(\.text) == ["😀 ", "é", "👩‍👩‍👧"])
        #expect(runs.map(\.isBold) == [true, false, false])
        #expect(runs.map(\.isItalic) == [false, false, true])
    }

    @Test("Runs that overrun the text are cut at its end")
    func overrun() throws {
        var message = PB()
        message.string(2, "Hello\nWorld")
        var run = PB()
        run.int(1, 100)
        run.int(5, 1)
        message.message(5, run)
        let paragraphs = try content(of: message).paragraphs
        #expect(paragraphs.map(\.text) == ["Hello", "World"])
        #expect(paragraphs.allSatisfy { $0.runs.allSatisfy(\.isBold) })
    }

    @Test("Text past the last run is body text")
    func textWithoutRuns() throws {
        var message = PB()
        message.string(2, "No runs\nat all")
        let paragraphs = try content(of: message).paragraphs
        #expect(paragraphs == [Note.Paragraph(runs: [Note.TextRun(text: "No runs")]), Note.Paragraph(runs: [Note.TextRun(text: "at all")])])
    }

    @Test("A final line feed doesn't add an empty paragraph")
    func finalLineFeed() throws {
        #expect(try content([RunSpec(text: "One\n")]).paragraphs.count == 1)
        #expect(try content([RunSpec(text: "One\n\n")]).paragraphs.count == 2)
        #expect(try content([]).paragraphs.isEmpty)
    }

    @Test("An attachment without a row keeps the identifier and type from the note")
    func missingAttachment() throws {
        let run = try content([RunSpec(text: "\u{FFFC}", attachment: ("MISSING", "com.adobe.pdf"))]).paragraphs[0].runs[0]
        #expect(run.text == "\u{FFFC}")
        #expect(run.attachment == Note.Attachment(id: .id("MISSING"), typeIdentifier: "com.adobe.pdf"))
        #expect(run.attachment?.kind == .pdf)
    }

    @Test("An attachment row's type takes precedence over the note's")
    func attachmentRowType() throws {
        let row = Database.AttachmentRow(attachment: Note.Attachment(id: .id("A"), typeIdentifier: "public.png", title: "Shot"), tableData: nil)
        let attachment = try content([RunSpec(text: "\u{FFFC}", attachment: ("A", "public.jpeg"))], rows: [.id("A"): row])
            .paragraphs[0].runs[0].attachment
        #expect(attachment?.typeIdentifier == "public.png")
        #expect(attachment?.title == "Shot")
    }

    @Test("A table inside itself is not decoded again")
    func tableCycle() throws {
        let data = tableData(
            [["x", "y"]],
            cellRuns: [
                "0,0": [RunSpec(text: "\u{FFFC}", attachment: ("LOOP", "com.apple.notes.table"))],
                "0,1": [RunSpec(text: "\u{FFFC}", attachment: ("LOOP", "com.apple.notes.table"))],
            ]
        )
        let row = Database.AttachmentRow(attachment: Note.Attachment(id: .id("LOOP"), typeIdentifier: "com.apple.notes.table"), tableData: data)
        let table = try #require(
            try content([RunSpec(text: "\u{FFFC}", attachment: ("LOOP", "com.apple.notes.table"))], rows: [.id("LOOP"): row])
                .paragraphs[0].runs[0].attachment?.table
        )
        let inner = table.rows[0].map { $0.paragraphs[0].runs[0].attachment }
        #expect(inner.map(\.?.id) == [.id("LOOP"), .id("LOOP")])
        #expect(inner.allSatisfy { $0?.table == nil })
    }

    @Test("Tables nested deeper than the limit are not decoded")
    func tableDepth() throws {
        // T0 holds T1, which holds T2, and so on.
        let count = AttachmentResolver.maximumDepth + 1
        var rows: [Note.Attachment.ID: Database.AttachmentRow] = [:]
        for index in 0 ..< count {
            let cell = index + 1 < count ? [RunSpec(text: "\u{FFFC}", attachment: ("T\(index + 1)", "com.apple.notes.table"))] : [RunSpec(text: "end")]
            rows[.id("T\(index)")] = Database.AttachmentRow(
                attachment: Note.Attachment(id: .id("T\(index)"), typeIdentifier: "com.apple.notes.table"),
                tableData: tableData([["x"]], cellRuns: ["0,0": cell])
            )
        }
        var attachment = try content([RunSpec(text: "\u{FFFC}", attachment: ("T0", "com.apple.notes.table"))], rows: rows)
            .paragraphs[0].runs[0].attachment
        var depth = 0
        while let table = attachment?.table {
            depth += 1
            attachment = table.rows[0][0].paragraphs[0].runs[0].attachment
        }
        #expect(depth == AttachmentResolver.maximumDepth)
        #expect(attachment?.id == .id("T\(AttachmentResolver.maximumDepth)"))
    }

    @Test("The resolver checks its budget for each table")
    func tableBudget() throws {
        struct Stop: Error {}
        let row = Database.AttachmentRow(
            attachment: Note.Attachment(id: .id("T"), typeIdentifier: "com.apple.notes.table"),
            tableData: tableData([["x"]])
        )
        var resolver = AttachmentResolver(loadRows: { _ in [.id("T"): row] }, checkBudget: { throw Stop() })
        let document = try NoteDocument(ProtobufMessage(Data(noteMessage([RunSpec(text: "\u{FFFC}", attachment: ("T", "com.apple.notes.table"))]).data)))
        #expect(throws: Stop.self) { try resolver.content(of: document) }
    }

    @Test("Integer fields keep their low 32 bits, so damaged lengths and styles can't overflow")
    func int32Fields() throws {
        var message = PB()
        message.string(2, "Hello\nWorld")
        for _ in 0 ..< 3 {
            var run = PB()
            run.int(1, 1 << 62)
            var style = PB()
            style.int(4, 1 << 40 | 2)
            style.int(7, Int(Int64.min))
            run.message(2, style)
            message.message(5, run)
        }
        let paragraphs = try content(of: message).paragraphs
        // 2^62 truncates to 0, so the text past the runs is body text.
        #expect(paragraphs.map(\.text) == ["Hello", "World"])

        var styled = PB()
        styled.string(2, "Item")
        var run = PB()
        run.int(1, 4)
        var style = PB()
        style.int(4, 1 << 40 | 2)
        style.int(7, Int(Int64.min))
        run.message(2, style)
        styled.message(5, run)
        let paragraph = try #require(try content(of: styled).paragraphs.first)
        #expect(paragraph.style.indent == 2)
        #expect(paragraph.style.startingNumber == 0)
    }
}

@Suite struct AttachmentKindTests {
    @Test(
        "Type identifiers map to kinds",
        arguments: [
            ("com.apple.notes.inlinetextattachment.hashtag", Note.Attachment.Kind.hashtag),
            ("com.apple.notes.inlinetextattachment.mention", .mention),
            ("com.apple.notes.inlinetextattachment.link", .noteLink),
            ("com.apple.notes.inlinetextattachment.calculateresult", .calculation),
            ("com.apple.notes.inlinetextattachment.calculategraphexpression", .calculation),
            ("com.apple.notes.inlinetextattachment.future", .inlineText),
            ("com.apple.notes.table", .table),
            ("public.url", .webLink),
            ("com.apple.drawing.2", .drawing),
            ("com.apple.paper", .drawing),
            ("com.apple.notes.sketch", .drawing),
            ("com.apple.notes.gallery", .scannedDocument),
            ("com.apple.paper.doc.scan", .scannedDocument),
            ("public.jpeg", .image),
            ("public.heic", .image),
            ("com.adobe.pdf", .pdf),
            ("com.apple.m4a-audio", .audio),
            ("com.apple.quicktime-movie", .video),
            ("public.vcard", .contact),
            ("com.apple.ical.ics", .file),
            ("", .file),
        ]
    )
    func kind(type: String, kind: Note.Attachment.Kind) {
        #expect(Note.Attachment(id: .id("A"), typeIdentifier: type).kind == kind)
    }

    @Test("Only tags, mentions, links, and calculations are inline")
    func inline() {
        let kinds: [Note.Attachment.Kind] = [
            .hashtag, .mention, .noteLink, .calculation, .inlineText, .table, .webLink, .drawing,
            .scannedDocument, .image, .pdf, .audio, .video, .contact, .file,
        ]
        #expect(kinds.filter(\.isInline) == [.hashtag, .mention, .noteLink, .calculation, .inlineText])
    }
}
