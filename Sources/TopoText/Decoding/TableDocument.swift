import Foundation

/// A table in a note, decoded from the `MergableDataProto` protocol buffer
/// that Notes stores, gzip-compressed, in the table attachment's `ZMERGEABLEDATA1` column.
///
/// The table is the state of a CRDT: a list of objects (`MergeableDataObjectEntry` [3]
/// of the `MergeableDataObjectData` at [2, 3]), with key names [4], type names [5],
/// and UUIDs [6] in side lists. Objects refer to one another by index (`ObjectID.object_index` [6]).
/// The `com.apple.notes.ICTable` object maps `crRows` and `crColumns` to ordered sets of UUIDs,
/// and `cellColumns` to a dictionary from each column's UUID to a dictionary from each
/// row's UUID to the cell's `Note`.
struct TableDocument {
    /// The cells, row by row, with each row from left to right; `nil` where a cell is empty.
    let rows: [[NoteDocument?]]
    /// Whether the table's columns run from right to left.
    let isRightToLeft: Bool

    /// Decodes the contents of a table attachment's mergeable data.
    /// - Throws: A ``FormatError`` if the data is not gzip-compressed table data.
    init(data: Data) throws {
        let root = try ProtobufMessage(data.gunzipped())
        guard let objectData = root.message(2)?.message(3) else {
            throw FormatError.unrecognized
        }
        let objects = objectData.messages(3)
        let keys = objectData.strings(4)
        let types = objectData.strings(5)
        let uuids = objectData.allBytes(6)

        func name(_ index: Int?, in names: [String]) -> String? {
            guard let index, names.indices.contains(index) else { return nil }
            return names[index]
        }

        /// The object that an `ObjectID` refers to, following registers
        /// (`register_latest` [1]) until it reaches an object with the given field.
        func object(_ reference: ProtobufMessage?, with field: Int) -> ProtobufMessage? {
            var reference = reference
            for _ in 0 ..< 8 {
                guard let index = reference?.integer(6), objects.indices.contains(index) else { return nil }
                let object = objects[index]
                if object.contains(field) {
                    return object
                }
                reference = object.message(1)?.message(2)
            }
            return nil
        }

        /// The index in `uuids` of the UUID that an `ObjectID` refers to,
        /// through an object of type `com.apple.CRDT.NSUUID` (`custom_map` [13]).
        func uuidIndex(_ reference: ProtobufMessage?) -> Int? {
            let entries = object(reference, with: 13)?.message(13)?.messages(3) ?? []
            let entry = entries.first { name($0.integer(1), in: keys) == "UUIDIndex" } ?? entries.first
            guard let index = entry?.message(2)?.integer(2), uuids.indices.contains(index) else { return nil }
            return index
        }

        /// The positions of the rows or columns that an ordered set lists, keyed by the index
        /// of the UUID that cells refer to them by.
        ///
        /// The set's ordering lists UUIDs by position (`array` [1, 1], `attachment` [2]) and maps
        /// each to the UUID of its row or column (`contents` [1, 2]). The set's `elements` [2]
        /// hold the positions that haven't been deleted. A row or column listed twice,
        /// as conflicting moves can leave it, takes its first position, as in Notes.
        func positions(of reference: ProtobufMessage?) -> [Int: Int] {
            guard let orderedSet = object(reference, with: 16)?.message(16),
                let ordering = orderedSet.message(1)
            else { return [:] }

            var contents: [Int: Int] = [:]
            for element in ordering.message(2)?.messages(1) ?? [] {
                if let key = uuidIndex(element.message(1)), let value = uuidIndex(element.message(2)) {
                    contents[key] = value
                }
            }
            let elements = Set((orderedSet.message(2)?.messages(1) ?? []).compactMap { uuidIndex($0.message(1)) })

            var positions: [Int: Int] = [:]
            for attachment in ordering.message(1)?.messages(2) ?? [] {
                guard let uuid = attachment.bytes(2), let index = uuids.firstIndex(of: uuid) else { continue }
                if !elements.isEmpty, !elements.contains(index) {
                    continue
                }
                let value = contents[index] ?? index
                if positions[value] == nil {
                    positions[value] = positions.count
                }
            }
            return positions
        }

        guard
            let table = objects.first(where: {
                name($0.message(13)?.integer(1), in: types) == "com.apple.notes.ICTable"
            })?.message(13)
        else {
            throw FormatError.unrecognized
        }

        var rowPositions: [Int: Int] = [:]
        var columnPositions: [Int: Int] = [:]
        var cellColumns: ProtobufMessage?
        for entry in table.messages(3) {
            switch name(entry.integer(1), in: keys) {
            case "crRows":
                rowPositions = positions(of: entry.message(2))
            case "crColumns":
                columnPositions = positions(of: entry.message(2))
            case "cellColumns":
                cellColumns = object(entry.message(2), with: 6)?.message(6)
            default:
                break
            }
        }

        // Every table has a row and a column, so an empty grid means the format is not the one read here.
        guard !rowPositions.isEmpty, !columnPositions.isEmpty else {
            throw FormatError.unrecognized
        }

        var rows = [[NoteDocument?]](
            repeating: [NoteDocument?](repeating: nil, count: columnPositions.count),
            count: rowPositions.count
        )
        for column in cellColumns?.messages(1) ?? [] {
            guard let columnPosition = uuidIndex(column.message(1)).flatMap({ columnPositions[$0] }) else {
                continue
            }
            for cell in object(column.message(2), with: 6)?.message(6)?.messages(1) ?? [] {
                guard let rowPosition = uuidIndex(cell.message(1)).flatMap({ rowPositions[$0] }),
                    let note = object(cell.message(2), with: 10)?.message(10)
                else { continue }
                rows[rowPosition][columnPosition] = NoteDocument(note)
            }
        }

        // The direction is stored as a string value somewhere among the table's objects.
        isRightToLeft = objects.contains { object in
            (object.message(13)?.messages(3) ?? []).contains {
                $0.message(2)?.string(4) == "CRTableColumnDirectionRightToLeft"
            }
        }
        self.rows = isRightToLeft ? rows.map { $0.reversed() } : rows
    }
}
