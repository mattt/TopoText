@testable import TopoText
import Foundation
import Testing

/// Renders notes decoded from a synthetic database, from the protocol buffer to Markdown and plain text.
@Suite struct RenderingTests {
    @Test("A note with every style renders as Markdown and plain text")
    func groceries() async throws {
        let folder = try NotesFolder.current()
        let content = try await Store(root: folder.root).content(for: .id("NOTE-GROCERIES"))

        #expect(
            content.markdown() == """
                # Groceries

                Plain **bold** and *italic* ***both*** 😀 ~~struck~~ [a link](https://example.com)

                ## Section

                ### Sub

                - [x] Milk
                - [ ] Eggs
                1. First
                2. Second
                    1. Nested
                3. Third
                - Dot
                    - Dash

                ```
                let x = 1
                let y = 2
                ```

                > Quoted

                Tag #groceries and [Other note](applenotes:note/0e5a3c7d-1111-4b4b-8c8c-000000000001?ownerIdentifier=_abc)
                [Image: Photo.jpeg]
                [Example](https://example.com/page)

                | Item | Qty |
                | --- | --- |
                | Milk | 1 |
                | Eggs | 12 |

                Last line without newline
                """
        )
        #expect(
            content.plainText() == """
                Groceries
                Plain bold and italic both 😀 struck a link
                Section
                Sub
                Milk
                Eggs
                First
                Second
                Nested
                Third
                Dot
                Dash
                let x = 1
                let y = 2
                Quoted
                Tag #groceries and Other note
                [Image: Photo.jpeg]
                Example (https://example.com/page)
                Item\tQty
                Milk\t1
                Eggs\t12
                Last line without newline
                """
        )
    }

    @Test("Tables, summaries, and missing attachments render as Markdown")
    func tables() async throws {
        let folder = try NotesFolder.current()
        let content = try await Store(root: folder.root).content(for: .id("NOTE-TABLES"))
        #expect(
            content.markdown() == """
                # Tables

                | Tag | Pipe |
                | --- | --- |
                | #pantry | a\\|b |

                Broken summary

                [Drawing] and missing [PDF]
                """
        )
    }

    @Test("Paragraph styles, line separators, starting numbers, and fences render as Markdown")
    func paragraphStyles() throws {
        let content = try content([
            RunSpec(text: "Start\n"),
            RunSpec(text: "Three", style: 102, start: 3),
            RunSpec(text: "\n"),
            RunSpec(text: "Four\n", style: 102, start: 3),
            RunSpec(text: "Line one\u{2028}line two\n", style: 103, checked: false),
            RunSpec(text: "\n", style: 103, checked: false),
            RunSpec(text: "Body\u{2028}more\n"),
            RunSpec(text: "Head\u{2028}ing\n", style: 1),
            RunSpec(text: "Said\u{2028}this\n", quote: true),
            RunSpec(text: "a ```` b", style: 4),
        ])
        #expect(
            content.markdown() == """
                Start

                3. Three
                4. Four
                - [ ] Line one
                      line two
                - [ ]

                Body
                more

                ## Head ing

                > Said
                > this

                `````
                a ```` b
                `````
                """
        )
        #expect(
            content.plainText() == "Start\nThree\nFour\nLine one\nline two\n\nBody\nmore\nHead\ning\nSaid\nthis\na ```` b"
        )
    }

    @Test("Table cells render with their line breaks")
    func tableCells() throws {
        let data = tableData([["A\n", "B\u{2028}C"]])
        let row = Database.AttachmentRow(attachment: Note.Attachment(id: .id("T"), typeIdentifier: "com.apple.notes.table"), tableData: data)
        let table = try #require(
            try content([RunSpec(text: "\u{FFFC}", attachment: ("T", "com.apple.notes.table"))], rows: [.id("T"): row])
                .paragraphs[0].runs[0].attachment?.table
        )
        #expect(Renderer(format: .plain).render(table) == "A\tB\nC")
        #expect(Renderer(format: .markdown).render(table) == "| A | B<br>C |\n| --- | --- |")
    }

    @Test("Short and unformatted contents render as is")
    func short() throws {
        #expect(try content([RunSpec(text: "Hi")]).markdown() == "Hi")
    }
}
