import Foundation

/// A run of note text and the attributes to encode with it.
struct RunSpec {
    var text: String
    var style: Int? = nil
    var indent: Int = 0
    var checked: Bool? = nil
    var start: Int? = nil
    var quote = false
    var alignment: Int? = nil
    var weight = 0
    var strike = false
    var underline = false
    var superscript: Int? = nil
    var link: String? = nil
    var color: (Float, Float, Float, Float)? = nil
    var highlight: Int? = nil
    var attachment: (String, String)? = nil
}

/// Encodes runs as a `Note` message: `note_text` [2] and `attribute_run` [5].
func noteMessage(_ runs: [RunSpec]) -> PB {
    var note = PB()
    note.string(2, runs.map(\.text).joined())
    for run in runs {
        var attributes = PB()
        attributes.int(1, run.text.utf16.count)
        if run.style != nil || run.indent > 0 || run.checked != nil || run.quote || run.start != nil || run.alignment != nil {
            var style = PB()
            if let kind = run.style { style.int(1, kind) }
            if let alignment = run.alignment { style.int(2, alignment) }
            if run.indent > 0 { style.int(4, run.indent) }
            if let checked = run.checked {
                var checklist = PB()
                checklist.bytes(1, Array(repeating: 7, count: 16))
                checklist.int(2, checked ? 1 : 0)
                style.message(5, checklist)
            }
            if let start = run.start { style.int(7, start) }
            if run.quote { style.int(8, 1) }
            attributes.message(2, style)
        }
        var font = PB()
        font.string(1, "Helvetica")
        font.float(2, 12)
        attributes.message(3, font)
        if run.weight != 0 { attributes.int(5, run.weight) }
        if run.underline { attributes.int(6, 1) }
        if run.strike { attributes.int(7, 1) }
        if let superscript = run.superscript { attributes.int(8, superscript) }
        if let link = run.link { attributes.string(9, link) }
        if let (red, green, blue, alpha) = run.color {
            var color = PB()
            color.float(1, red)
            color.float(2, green)
            color.float(3, blue)
            color.float(4, alpha)
            attributes.message(10, color)
        }
        if let (identifier, type) = run.attachment {
            var info = PB()
            info.string(1, identifier)
            info.string(2, type)
            attributes.message(12, info)
        }
        if let highlight = run.highlight { attributes.int(14, highlight) }
        note.message(5, attributes)
    }
    return note
}

/// Encodes runs as the uncompressed contents of `ZICNOTEDATA.ZDATA`.
func noteProtobuf(_ runs: [RunSpec]) -> [UInt8] {
    var document = PB()
    document.int(2, 0)
    document.message(3, noteMessage(runs))
    var root = PB()
    root.message(2, document)
    return root.data
}

/// Encodes runs as the gzip-compressed contents of `ZICNOTEDATA.ZDATA`.
func noteData(_ runs: [RunSpec]) -> Data {
    gzip(noteProtobuf(runs))
}

/// Encodes a table as gzip-compressed `MergableDataProto`, the structure that `TableDocument` documents.
/// - Parameters:
///   - cells: The text of the cells, row by row, in logical order.
///   - rowOrder: The display order of the rows, as indexes into `cells`.
///   - deletedRows: Rows to leave out of the ordered set's elements, as a deletion does.
///   - duplicateFirstColumn: Whether to list the first column twice, as conflicting moves do.
///   - rightToLeft: Whether the table's direction is right to left.
///   - cellRuns: Runs for cells, keyed by `"row,column"`, in place of plain text.
///   - wrapCellsInRegisters: Whether to refer to cells through `register_latest` objects.
func tableData(
    _ cells: [[String]],
    rowOrder: [Int]? = nil,
    deletedRows: Set<Int> = [],
    duplicateFirstColumn: Bool = false,
    rightToLeft: Bool = false,
    cellRuns: [String: [RunSpec]] = [:],
    wrapCellsInRegisters: Bool = false
) -> Data {
    let rowCount = cells.count
    let columnCount = cells[0].count
    var uuids: [[UInt8]] = []
    func newUUID() -> Int {
        uuids.append(withUnsafeBytes(of: UUID().uuid) { Array($0) })
        return uuids.count - 1
    }
    let keys = ["identity", "crTableColumnDirection", "self", "crRows", "UUIDIndex", "crColumns", "cellColumns"]
    func key(_ name: String) -> Int { keys.firstIndex(of: name)! }
    let types = ["com.apple.CRDT.NSUUID", "com.apple.notes.ICTable", "com.apple.CRDT.NSString"]
    var entries: [PB] = []
    func add(_ entry: PB) -> Int {
        entries.append(entry)
        return entries.count - 1
    }
    func objectID(_ index: Int) -> PB {
        var object = PB()
        object.int(6, index)
        return object
    }
    func uuidObject(_ uuidIndex: Int) -> Int {
        var value = PB()
        value.int(2, uuidIndex)
        var entry = PB()
        entry.int(1, key("UUIDIndex"))
        entry.message(2, value)
        var map = PB()
        map.int(1, 0)
        map.message(3, entry)
        var object = PB()
        object.message(13, map)
        return add(object)
    }
    func orderedSet(_ count: Int, order: [Int], deleted: Set<Int>, duplicateFirst: Bool) -> (Int, [Int]) {
        // Ordering UUIDs (the array's) map to element UUIDs (the ones that cells use).
        let orderingUUIDs = (0 ..< count).map { _ in newUUID() }
        let elementUUIDs = (0 ..< count).map { _ in newUUID() }
        var array = PB()
        var contentsNote = PB()
        contentsNote.string(2, "")
        array.message(1, contentsNote)
        var listed = order
        if duplicateFirst { listed.append(order[0]) }
        for (position, item) in listed.enumerated() {
            var attachment = PB()
            attachment.int(1, position)
            attachment.bytes(2, uuids[orderingUUIDs[item]])
            array.message(2, attachment)
        }
        var contents = PB()
        for index in 0 ..< count {
            var element = PB()
            element.message(1, objectID(uuidObject(orderingUUIDs[index])))
            element.message(2, objectID(uuidObject(elementUUIDs[index])))
            contents.message(1, element)
        }
        var elements = PB()
        for index in 0 ..< count where !deleted.contains(index) {
            var element = PB()
            element.message(1, objectID(uuidObject(orderingUUIDs[index])))
            element.message(2, objectID(uuidObject(orderingUUIDs[index])))
            elements.message(1, element)
        }
        var ordering = PB()
        ordering.message(1, array)
        ordering.message(2, contents)
        var set = PB()
        set.message(1, ordering)
        set.message(2, elements)
        var object = PB()
        object.message(16, set)
        return (add(object), elementUUIDs)
    }
    /// Wraps an object in a register that points to it.
    func register(_ index: Int) -> Int {
        guard wrapCellsInRegisters else { return index }
        var contents = PB()
        contents.message(2, objectID(index))
        var object = PB()
        object.message(1, contents)
        return add(object)
    }

    let (rowsObject, rowUUIDs) = orderedSet(
        rowCount,
        order: rowOrder ?? Array(0 ..< rowCount),
        deleted: deletedRows,
        duplicateFirst: false
    )
    let (columnsObject, columnUUIDs) = orderedSet(
        columnCount,
        order: Array(0 ..< columnCount),
        deleted: [],
        duplicateFirst: duplicateFirstColumn
    )
    var columnsDictionary = PB()
    for column in 0 ..< columnCount {
        var rowsDictionary = PB()
        for row in 0 ..< rowCount where !cells[row][column].isEmpty || cellRuns["\(row),\(column)"] != nil {
            var cell = PB()
            cell.message(10, noteMessage(cellRuns["\(row),\(column)"] ?? [RunSpec(text: cells[row][column])]))
            let cellIndex = register(add(cell))
            var element = PB()
            element.message(1, objectID(uuidObject(rowUUIDs[row])))
            element.message(2, objectID(cellIndex))
            rowsDictionary.message(1, element)
        }
        var rows = PB()
        rows.message(6, rowsDictionary)
        let rowsIndex = register(add(rows))
        var element = PB()
        element.message(1, objectID(uuidObject(columnUUIDs[column])))
        element.message(2, objectID(rowsIndex))
        columnsDictionary.message(1, element)
    }
    var cellColumns = PB()
    cellColumns.message(6, columnsDictionary)
    let cellColumnsIndex = add(cellColumns)

    var directionValue = PB()
    directionValue.string(4, rightToLeft ? "CRTableColumnDirectionRightToLeft" : "CRTableColumnDirectionLeftToRight")
    var directionEntry = PB()
    directionEntry.int(1, key("self"))
    directionEntry.message(2, directionValue)
    var directionMap = PB()
    directionMap.int(1, 2)
    directionMap.message(3, directionEntry)
    var direction = PB()
    direction.message(13, directionMap)
    let directionIndex = add(direction)

    var tableMap = PB()
    tableMap.int(1, 1)
    for (name, index) in [
        ("crTableColumnDirection", directionIndex), ("crRows", rowsObject), ("crColumns", columnsObject), ("cellColumns", cellColumnsIndex),
    ] {
        var entry = PB()
        entry.int(1, key(name))
        entry.message(2, objectID(index))
        tableMap.message(3, entry)
    }
    var table = PB()
    table.message(13, tableMap)
    _ = add(table)

    var objectData = PB()
    for entry in entries { objectData.message(3, entry) }
    for name in keys { objectData.string(4, name) }
    for type in types { objectData.string(5, type) }
    for uuid in uuids { objectData.bytes(6, uuid) }
    var object = PB()
    object.int(2, 0)
    object.message(3, objectData)
    var root = PB()
    root.message(2, object)
    return gzip(root.data)
}
