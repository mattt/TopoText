@testable import TopoText
import Foundation
import Testing

@Suite struct TableTests {
    /// Decodes table data as the table of an attachment in a note.
    func table(_ data: Data) throws -> Note.Table? {
        let row = Database.AttachmentRow(attachment: Note.Attachment(id: .id("T"), typeIdentifier: "com.apple.notes.table"), tableData: data)
        return try content([RunSpec(text: "\u{FFFC}", attachment: ("T", "com.apple.notes.table"))], rows: [.id("T"): row])
            .paragraphs[0].runs[0].attachment?.table
    }

    /// The plain text of each cell.
    func cells(_ data: Data) throws -> [[String]] {
        try #require(try table(data)).rows.map { $0.map { Renderer(format: .plain).render($0) } }
    }

    @Test("Cells come out row by row")
    func cells() throws {
        #expect(try cells(tableData([["A", "B"], ["1", ""]])) == [["A", "B"], ["1", ""]])
    }

    @Test("Rows follow the ordering array")
    func rowOrder() throws {
        #expect(try cells(tableData([["A", "B"], ["1", "2"], ["3", ""]], rowOrder: [2, 0, 1])) == [["3", ""], ["A", "B"], ["1", "2"]])
    }

    @Test("Deleted rows are left out")
    func deletedRow() throws {
        #expect(try cells(tableData([["A", "B"], ["1", "2"], ["3", "4"]], deletedRows: [1])) == [["A", "B"], ["3", "4"]])
    }

    @Test("A column listed twice takes its first position")
    func duplicateColumn() throws {
        #expect(try cells(tableData([["A", "B"], ["1", "2"]], duplicateFirstColumn: true)) == [["A", "B"], ["1", "2"]])
    }

    @Test("A right-to-left table reverses its columns")
    func rightToLeft() throws {
        let table = try #require(try table(tableData([["A", "B"], ["1", "2"]], rightToLeft: true)))
        #expect(table.isRightToLeft)
        #expect(table.rows.map { $0.map { Renderer(format: .plain).render($0) } } == [["B", "A"], ["2", "1"]])
        #expect(try #require(try self.table(tableData([["A"]]))).isRightToLeft == false)
    }

    @Test("Registers that point to cells are followed")
    func registers() throws {
        #expect(try cells(tableData([["A", "B"], ["1", "2"]], wrapCellsInRegisters: true)) == [["A", "B"], ["1", "2"]])
    }

    @Test("Cells keep their paragraphs and formatting")
    func cellContents() throws {
        let data = tableData(
            [["", "B\u{2028}C"]],
            cellRuns: ["0,0": [RunSpec(text: "Bold\n", weight: 1), RunSpec(text: "Item", style: 100)]]
        )
        let row = try #require(try table(data)).rows[0]
        #expect(row[0].paragraphs.map(\.text) == ["Bold", "Item"])
        #expect(row[0].paragraphs[0].runs[0].isBold)
        #expect(row[0].paragraphs[1].style.kind == .bulletedList)
        #expect(row[1].paragraphs.map(\.text) == ["B\u{2028}C"])
    }

    @Test("A table that decodes to no cells is not decoded, so its summary stands in")
    func emptyGrid() throws {
        // An ICTable object without rows or columns.
        var map = PB()
        map.int(1, 0)
        var object = PB()
        object.message(13, map)
        var objectData = PB()
        objectData.message(3, object)
        objectData.string(5, "com.apple.notes.ICTable")
        var data = PB()
        data.int(2, 0)
        data.message(3, objectData)
        var root = PB()
        root.message(2, data)
        #expect(throws: FormatError.unrecognized) { try TableDocument(data: gzip(root.data)) }
        #expect(try table(gzip(root.data)) == nil)
    }

    @Test("Table data that can't be decoded leaves the table empty")
    func undecodable() throws {
        #expect(try table(Data([0x1F, 0x8B, 0x08, 0x00])) == nil)
        #expect(try table(gzip([0x08, 0x01])) == nil)
    }
}
