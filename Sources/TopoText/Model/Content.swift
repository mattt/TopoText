import Foundation

extension Note {
    /// The contents of a note or of a table cell, as paragraphs of formatted text.
    ///
    /// The paragraphs follow the note's line feeds.
    /// Within a paragraph, a line separator (U+2028) breaks a line without starting a new paragraph.
    /// Each attachment stands in the text as an object replacement character (U+FFFC)
    /// in a run of its own, with the attachment's details in ``TextRun/attachment``.
    ///
    /// ``Store/content(for:)`` returns the contents of a note.
    /// You can also create contents directly, for example to test code that renders them.
    public struct Content: Sendable, Hashable {
        /// The paragraphs, in order.
        ///
        /// A final paragraph without a line feed is included only if it has text.
        public let paragraphs: [Paragraph]

        /// Creates contents from paragraphs.
        /// - Parameter paragraphs: The paragraphs, in order.
        public init(paragraphs: [Paragraph] = []) {
            self.paragraphs = paragraphs
        }
    }

    /// A paragraph of a note: the text up to a line feed, and the paragraph's style.
    public struct Paragraph: Sendable, Hashable {
        /// The style of the paragraph.
        ///
        /// Notes stores a style with each run.
        /// The paragraph takes the style of the run that covers its first character,
        /// which for an empty paragraph is its line feed.
        public let style: ParagraphStyle
        /// The runs of text in the paragraph, without its line feed.
        ///
        /// An empty paragraph has no runs.
        public let runs: [TextRun]

        /// Creates a paragraph.
        /// - Parameters:
        ///   - style: The style of the paragraph.
        ///   - runs: The runs of text in the paragraph, without its line feed.
        public init(style: ParagraphStyle = ParagraphStyle(), runs: [TextRun] = []) {
            self.style = style
            self.runs = runs
        }

        /// The text of the paragraph, with an object replacement character (U+FFFC) for each attachment.
        public var text: String {
            runs.map(\.text).joined()
        }
    }

    /// The style of a paragraph: its kind, such as a heading or a checklist item, and its layout.
    public struct ParagraphStyle: Sendable, Hashable {
        /// The kind of a paragraph, from the style menu in Notes.
        public enum Kind: Sendable, Hashable {
            /// Body text, the style of paragraphs without another kind.
            case body
            /// A title.
            case title
            /// A heading.
            case heading
            /// A subheading.
            case subheading
            /// Monospaced text, such as code.
            case monospaced
            /// An item of a bulleted list.
            case bulletedList
            /// An item of a dashed list.
            case dashedList
            /// An item of a numbered list.
            case numberedList
            /// An item of a checklist.
            case checklist

            /// A Boolean value that indicates whether the kind is a title, heading, or subheading.
            public var isHeading: Bool {
                switch self {
                case .title, .heading, .subheading: return true
                default: return false
                }
            }

            /// A Boolean value that indicates whether the kind is an item of a list or checklist.
            public var isList: Bool {
                switch self {
                case .bulletedList, .dashedList, .numberedList, .checklist: return true
                default: return false
                }
            }

            /// Creates a kind from the `style_type` value that Notes stores.
            init?(styleType: Int) {
                switch styleType {
                case -1: self = .body
                case 0: self = .title
                case 1: self = .heading
                case 2: self = .subheading
                case 4: self = .monospaced
                case 100: self = .bulletedList
                case 101: self = .dashedList
                case 102: self = .numberedList
                case 103: self = .checklist
                default: return nil
                }
            }
        }

        /// The horizontal alignment of a paragraph's lines.
        public enum Alignment: Sendable, Hashable {
            /// Lines align to the left edge.
            case left
            /// Lines are centered.
            case center
            /// Lines align to the right edge.
            case right
            /// Lines fill the width, except the last.
            case justified

            /// Creates an alignment from the `alignment` value that Notes stores.
            init?(storedValue: Int) {
                switch storedValue {
                case 0: self = .left
                case 1: self = .center
                case 2: self = .right
                case 3: self = .justified
                default: return nil
                }
            }
        }

        /// The kind of the paragraph.
        ///
        /// A style that TopoText does not recognize reads as ``Kind/body``.
        public let kind: Kind
        /// The nesting level of a list item or an indented paragraph, starting at 0.
        public let indent: Int
        /// A Boolean value that indicates whether a checklist item is checked.
        ///
        /// The value is `false` for paragraphs that are not checklist items.
        public let isChecked: Bool
        /// The number that a numbered list starts from, if Notes records one.
        ///
        /// Notes records the number on the items of a list that does not start at 1.
        public let startingNumber: Int?
        /// A Boolean value that indicates whether the paragraph is a block quote.
        public let isBlockQuote: Bool
        /// The alignment of the paragraph, or `nil` if it has the default alignment.
        public let alignment: Alignment?

        /// Creates a paragraph style.
        /// - Parameters:
        ///   - kind: The kind of the paragraph.
        ///   - indent: The nesting level, starting at 0.
        ///   - isChecked: Whether a checklist item is checked.
        ///   - startingNumber: The number that a numbered list starts from, if any.
        ///   - isBlockQuote: Whether the paragraph is a block quote.
        ///   - alignment: The alignment, or `nil` for the default alignment.
        public init(
            kind: Kind = .body,
            indent: Int = 0,
            isChecked: Bool = false,
            startingNumber: Int? = nil,
            isBlockQuote: Bool = false,
            alignment: Alignment? = nil
        ) {
            self.kind = kind
            self.indent = indent
            self.isChecked = isChecked
            self.startingNumber = startingNumber
            self.isBlockQuote = isBlockQuote
            self.alignment = alignment
        }
    }

    /// A run of text with the same formatting, or an attachment.
    public struct TextRun: Sendable, Hashable {
        /// The highlight colors that Notes offers.
        public enum Highlight: Sendable, Hashable {
            /// A purple highlight.
            case purple
            /// A pink highlight.
            case pink
            /// An orange highlight.
            case orange
            /// A mint highlight.
            case mint
            /// A blue highlight.
            case blue

            /// Creates a highlight from the `emphasis_style` value that Notes stores.
            init?(emphasisStyle: Int) {
                switch emphasisStyle {
                case 1: self = .purple
                case 2: self = .pink
                case 3: self = .orange
                case 4: self = .mint
                case 5: self = .blue
                default: return nil
                }
            }
        }

        /// The vertical position of text relative to the baseline.
        public enum BaselinePosition: Sendable, Hashable {
            /// Text on the baseline.
            case normal
            /// Raised text.
            case superscript
            /// Lowered text.
            case `subscript`
        }

        /// A color with red, green, blue, and alpha components from 0 through 1.
        public struct Color: Sendable, Hashable {
            /// The red component.
            public let red: Double
            /// The green component.
            public let green: Double
            /// The blue component.
            public let blue: Double
            /// The alpha component, where 1 is opaque.
            public let alpha: Double

            /// Creates a color.
            /// - Parameters:
            ///   - red: The red component, from 0 through 1.
            ///   - green: The green component, from 0 through 1.
            ///   - blue: The blue component, from 0 through 1.
            ///   - alpha: The alpha component, from 0 through 1, where 1 is opaque.
            public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
                self.red = red
                self.green = green
                self.blue = blue
                self.alpha = alpha
            }
        }

        /// The text of the run.
        ///
        /// The text can contain line separators (U+2028), which break lines within the paragraph.
        /// For an attachment, the text is one object replacement character (U+FFFC).
        public internal(set) var text: String
        /// A Boolean value that indicates whether the text is bold.
        public internal(set) var isBold: Bool
        /// A Boolean value that indicates whether the text is italic.
        public internal(set) var isItalic: Bool
        /// A Boolean value that indicates whether the text is underlined.
        public internal(set) var isUnderlined: Bool
        /// A Boolean value that indicates whether the text is struck through.
        public internal(set) var isStrikethrough: Bool
        /// The vertical position of the text.
        public internal(set) var baselinePosition: BaselinePosition
        /// The highlight color, if the text has a highlight that TopoText recognizes.
        public internal(set) var highlight: Highlight?
        /// The color of the text, if it is not the default color.
        public internal(set) var color: Color?
        /// The target of a link, such as a web URL or an `applenotes:note/…` link to another note.
        public internal(set) var link: String?
        /// The attachment that the run stands for, if any.
        public internal(set) var attachment: Attachment?

        /// Creates a run.
        /// - Parameters:
        ///   - text: The text of the run.
        ///   - isBold: Whether the text is bold.
        ///   - isItalic: Whether the text is italic.
        ///   - isUnderlined: Whether the text is underlined.
        ///   - isStrikethrough: Whether the text is struck through.
        ///   - baselinePosition: The vertical position of the text.
        ///   - highlight: The highlight color, if any.
        ///   - color: The color of the text, if it is not the default color.
        ///   - link: The target of a link, if any.
        ///   - attachment: The attachment that the run stands for, if any.
        public init(
            text: String,
            isBold: Bool = false,
            isItalic: Bool = false,
            isUnderlined: Bool = false,
            isStrikethrough: Bool = false,
            baselinePosition: BaselinePosition = .normal,
            highlight: Highlight? = nil,
            color: Color? = nil,
            link: String? = nil,
            attachment: Attachment? = nil
        ) {
            self.text = text
            self.isBold = isBold
            self.isItalic = isItalic
            self.isUnderlined = isUnderlined
            self.isStrikethrough = isStrikethrough
            self.baselinePosition = baselinePosition
            self.highlight = highlight
            self.color = color
            self.link = link
            self.attachment = attachment
        }

        /// The identifier of the note that the run's link opens, if the link is to another note.
        public var linkedNoteID: Note.ID? {
            link.flatMap(noteID(inLink:))
        }
    }
}
