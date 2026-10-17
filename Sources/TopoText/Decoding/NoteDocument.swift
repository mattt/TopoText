import Foundation

/// The text of a note and the attributes of its runs, as stored.
///
/// Notes stores each note as a gzip-compressed `NoteStoreProto` protocol buffer
/// in `ZICNOTEDATA.ZDATA`, with this structure (field numbers in brackets):
///
/// - `NoteStoreProto`: `document` [2]
/// - `Document`: `version` [2], `note` [3]
/// - `Note`: `note_text` [2], repeated `attribute_run` [5]
/// - `AttributeRun`: `length` [1], `paragraph_style` [2], `font_weight` [5],
///   `underlined` [6], `strikethrough` [7], `superscript` [8], `link` [9],
///   `color` [10], `attachment_info` [12], `emphasis_style` [14]
/// - `ParagraphStyle`: `style_type` [1], `alignment` [2], `indent_amount` [4], `checklist` [5],
///   `starting_list_item_number` [7], `block_quote` [8]
/// - `Checklist`: `uuid` [1], `done` [2]
/// - `Color`: `red` [1], `green` [2], `blue` [3], `alpha` [4], as floats
/// - `AttachmentInfo`: `attachment_identifier` [1], `type_uti` [2]
///
/// Run lengths count UTF-16 code units, as `NSString` does.
/// A line feed ends a paragraph, and U+2028 breaks a line within one.
/// Each attachment stands in the text as an object replacement character (U+FFFC).
struct NoteDocument {
    /// An attachment as the note text refers to it.
    struct AttachmentReference: Hashable {
        let identifier: Note.Attachment.ID
        let typeIdentifier: String?
    }

    struct Run {
        /// The number of UTF-16 code units the run covers.
        var length: Int
        var paragraphStyle: Note.ParagraphStyle?
        /// The run's formatting, with empty text.
        var format = Note.TextRun(text: "")
        var attachment: AttachmentReference?

        init(length: Int) {
            self.length = length
        }

        init(_ message: ProtobufMessage) {
            length = max(0, message.int32(1) ?? 0)
            paragraphStyle = message.message(2).map(Note.ParagraphStyle.init)
            // 1 is bold, 2 italic, and 3 both.
            let fontWeight = message.int32(5) ?? 0
            format.isBold = fontWeight == 1 || fontWeight == 3
            format.isItalic = fontWeight == 2 || fontWeight == 3
            format.isUnderlined = (message.int32(6) ?? 0) != 0
            format.isStrikethrough = (message.int32(7) ?? 0) != 0
            // The sign tells superscript from subscript.
            switch message.int32(8) ?? 0 {
            case 1...: format.baselinePosition = .superscript
            case ..<0: format.baselinePosition = .subscript
            default: format.baselinePosition = .normal
            }
            format.link = message.string(9).flatMap { $0.isEmpty ? nil : $0 }
            if let color = message.message(10) {
                format.color = Note.TextRun.Color(
                    red: Double(color.float(1) ?? 0),
                    green: Double(color.float(2) ?? 0),
                    blue: Double(color.float(3) ?? 0),
                    alpha: Double(color.float(4) ?? 1)
                )
            }
            format.highlight = message.int32(14).flatMap(Note.TextRun.Highlight.init(emphasisStyle:))
            if let info = message.message(12), let identifier = info.string(1).flatMap(Note.Attachment.ID.init(_:)) {
                attachment = AttachmentReference(
                    identifier: identifier,
                    typeIdentifier: info.string(2).flatMap { $0.isEmpty ? nil : $0 }
                )
            }
        }
    }

    /// A paragraph of the note and the runs that make it up, without its line feed.
    struct Paragraph {
        var segments: [(text: String, run: Run)] = []
        /// The paragraph style of the run that holds the paragraph's first character.
        var style: Note.ParagraphStyle?
    }

    let text: String
    let runs: [Run]

    /// Decodes the contents of `ZICNOTEDATA.ZDATA`.
    /// - Throws: A ``FormatError`` if the data is not gzip-compressed note contents.
    init(data: Data) throws {
        let root = try ProtobufMessage(data.gunzipped())
        guard let note = root.message(2)?.message(3) else {
            throw FormatError.unrecognized
        }
        self.init(note)
    }

    /// Reads a `Note` message, as found in note contents and in table cells.
    init(_ note: ProtobufMessage) {
        text = note.string(2) ?? ""
        runs = note.messages(5).map(Run.init)
    }

    /// The attachments that the runs refer to.
    var attachments: [AttachmentReference] {
        runs.compactMap(\.attachment)
    }

    /// The text split into paragraphs, each with the runs that cover it.
    /// Text past the last run, if any, is treated as body text.
    var paragraphs: [Paragraph] {
        let text = self.text as NSString
        var runs = self.runs
        let covered = runs.reduce(0) { $0 + $1.length }
        if covered < text.length {
            runs.append(Run(length: text.length - covered))
        }

        var paragraphs: [Paragraph] = []
        var current = Paragraph()
        var hasStyle = false
        var offset = 0
        for run in runs where offset < text.length {
            let length = min(run.length, text.length - offset)
            guard length > 0 else { continue }
            let lines = text.substring(with: NSRange(location: offset, length: length))
                .components(separatedBy: "\n")
            offset += length

            for (index, line) in lines.enumerated() {
                let endsParagraph = index < lines.count - 1
                // An empty paragraph's first character is its line feed.
                if !hasStyle, !line.isEmpty || endsParagraph {
                    current.style = run.paragraphStyle
                    hasStyle = true
                }
                if !line.isEmpty {
                    current.segments.append((line, run))
                }
                if endsParagraph {
                    paragraphs.append(current)
                    current = Paragraph()
                    hasStyle = false
                }
            }
        }
        if !current.segments.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }
}

extension Note.ParagraphStyle {
    /// Reads a `ParagraphStyle` message.
    init(_ message: ProtobufMessage) {
        self.init(
            kind: message.int32(1).flatMap(Kind.init(styleType:)) ?? .body,
            indent: max(0, message.int32(4) ?? 0),
            isChecked: message.message(5)?.int32(2) == 1,
            startingNumber: message.int32(7),
            isBlockQuote: (message.int32(8) ?? 0) != 0,
            alignment: message.int32(2).flatMap(Alignment.init(storedValue:))
        )
    }
}
