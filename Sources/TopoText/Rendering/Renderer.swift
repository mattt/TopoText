import Foundation

/// Renders contents as Markdown or plain text, for ``Note/Content/markdown()``
/// and ``Note/Content/plainText()``.
struct Renderer {
    enum Format {
        case markdown
        case plain
    }

    let format: Format

    func render(_ content: Note.Content) -> String {
        switch format {
        case .plain:
            return content.paragraphs.map { paragraph in
                paragraph.runs.map { plainText($0) }.joined()
                    .replacingOccurrences(of: "\u{2028}", with: "\n")
            }.joined(separator: "\n")
        case .markdown:
            return markdown(content.paragraphs)
        }
    }

    /// Renders a table as a Markdown table with the first row as its header,
    /// or as plain text with tabs between cells.
    func render(_ table: Note.Table) -> String {
        let cellRenderer = Renderer(format: .plain)
        let rows = table.rows.map { row in
            row.map { cell in
                var text = cellRenderer.render(cell)
                while text.hasSuffix("\n") {
                    text.removeLast()
                }
                return text
            }
        }
        guard let header = rows.first, !header.isEmpty else { return "" }

        switch format {
        case .plain:
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .markdown:
            func line(_ cells: [String]) -> String {
                let cells = cells.map {
                    Self.escaped($0)
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: "<br>")
                }
                return "| " + cells.joined(separator: " | ") + " |"
            }
            return ([line(header), line(header.map { _ in "---" })] + rows.dropFirst().map(line))
                .joined(separator: "\n")
        }
    }

    /// The text that stands in for an attachment.
    /// In Markdown, its text is escaped unless `escaping` is `false`, as in code blocks.
    private func text(for attachment: Note.Attachment, escaping: Bool = true) -> String {
        func escape(_ text: String) -> String {
            format == .markdown && escaping ? Self.escaped(text) : text
        }
        if attachment.kind == .webLink, let url = attachment.url?.absoluteString {
            switch format {
            case .markdown: return "[\(escape(attachment.title ?? url))](\(url))"
            case .plain: return attachment.title.map { "\($0) (\(url))" } ?? url
            }
        }

        switch attachment.kind {
        // Tags, mentions, links to other notes, and math results.
        case .hashtag, .mention, .noteLink, .calculation, .inlineText:
            let text = attachment.displayText ?? ""
            if format == .markdown, attachment.kind == .noteLink, let target = attachment.tokenIdentifier,
                !text.isEmpty
            {
                return "[\(escape(text))](\(target))"
            }
            return escape(text)
        case .table:
            guard let table = attachment.table else {
                return attachment.summary ?? "[Table]"
            }
            return render(table)
        default:
            let kind: String
            switch attachment.kind {
            case .drawing: kind = "Drawing"
            case .scannedDocument: kind = "Scanned document"
            case .image: kind = "Image"
            case .pdf: kind = "PDF"
            case .audio: kind = "Audio"
            case .video: kind = "Video"
            case .contact: kind = "Contact"
            default: kind = "Attachment"
            }
            if let name = attachment.title ?? attachment.fileName {
                return "[\(kind): \(escape(name))]"
            }
            return "[\(kind)]"
        }
    }

    private func plainText(_ run: Note.TextRun, escaping: Bool = true) -> String {
        if let attachment = run.attachment {
            return text(for: attachment, escaping: escaping)
        }
        return run.text.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private enum Block: Equatable {
        case text
        case heading
        case list
        case quote
        case code
        case table
    }

    private func markdown(_ paragraphs: [Note.Paragraph]) -> String {
        var lines: [String] = []
        var lastBlock: Block?
        var code: [String] = []
        // The last number used in a numbered list, by indent level.
        var numbers: [Int: Int] = [:]

        // Adds lines, with a blank line before them when they start a different kind
        // of block, so that each renders on its own.
        func emit(_ block: Block, _ text: String) {
            guard !text.isEmpty else {
                lines.append("")
                return
            }
            if let lastBlock, lastBlock != block || [.heading, .code, .table].contains(block),
                lines.last?.isEmpty == false
            {
                lines.append("")
            }
            lines.append(text)
            lastBlock = block
        }

        func emitCode() {
            guard !code.isEmpty else { return }
            let text = code.joined(separator: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
            // The fence must be longer than any run of backticks in the code.
            var longestRun = 0
            var run = 0
            for character in text {
                run = character == "`" ? run + 1 : 0
                longestRun = max(longestRun, run)
            }
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            emit(.code, fence + "\n" + text + "\n" + fence)
            code = []
        }

        for paragraph in paragraphs {
            let style = paragraph.style
            if style.kind == .monospaced {
                // A code block ends any list, as other paragraphs do.
                numbers = [:]
                code.append(paragraph.runs.map { plainText($0, escaping: false) }.joined())
                continue
            }
            emitCode()

            if paragraph.runs.count == 1, let attachment = paragraph.runs[0].attachment,
                attachment.kind == .table
            {
                numbers = [:]
                emit(.table, text(for: attachment))
                continue
            }

            let indent = style.indent
            if style.kind == .numberedList {
                numbers = numbers.filter { $0.key <= indent }
            } else {
                // Outer numbered lists continue past nested items; anything else ends them.
                numbers = numbers.filter { style.kind.isList && $0.key < indent }
            }

            let content = inlineMarkdown(paragraph.runs)
                .split(separator: "\u{2028}", omittingEmptySubsequences: false)
                .map(Self.escapingLineStart)
                .joined(separator: "\u{2028}")
            var prefix: String
            switch style.kind {
            case .title: prefix = "# "
            case .heading: prefix = "## "
            case .subheading: prefix = "### "
            case .bulletedList, .dashedList: prefix = "- "
            case .numberedList:
                let number = (numbers[indent] ?? ((style.startingNumber ?? 1) - 1)) + 1
                numbers[indent] = number
                prefix = "\(number). "
            case .checklist: prefix = style.isChecked ? "- [x] " : "- [ ] "
            case .monospaced, .body: prefix = ""
            }

            let block: Block
            var lineBreak: String
            if style.kind.isList {
                prefix = String(repeating: "    ", count: indent) + prefix
                block = .list
                // Continuation lines line up with the item's text, to stay within the item.
                lineBreak = "\n" + String(repeating: " ", count: prefix.count)
            } else if style.kind.isHeading {
                block = .heading
                lineBreak = " "
            } else {
                block = .text
                lineBreak = "\n"
            }
            if style.isBlockQuote {
                prefix = "> " + prefix
                lineBreak = lineBreak == " " ? " " : "\n> " + lineBreak.dropFirst()
            }
            guard !content.isEmpty else {
                emit(block, style.kind.isList ? prefix.trimmingCharacters(in: .whitespaces) : "")
                continue
            }
            let text = prefix + content.replacingOccurrences(of: "\u{2028}", with: lineBreak)
            emit(style.isBlockQuote ? .quote : block, text)
        }
        emitCode()
        return lines.joined(separator: "\n")
    }

    /// The Markdown for a paragraph's runs: bold, italic, strikethrough, links, and attachments.
    /// Underlining has no Markdown equivalent and is left out.
    private func inlineMarkdown(_ runs: [Note.TextRun]) -> String {
        // Merge neighboring runs with the same formatting, so that markers are not
        // closed and reopened between them.
        var merged: [(text: String, run: Note.TextRun)] = []
        for run in runs {
            if let last = merged.last?.run, last.attachment == nil, run.attachment == nil,
                last.isBold == run.isBold, last.isItalic == run.isItalic,
                last.isStrikethrough == run.isStrikethrough, last.link == run.link
            {
                merged[merged.count - 1].text += plainText(run)
            } else {
                merged.append((plainText(run), run))
            }
        }

        return merged.map { text, run in
            if run.attachment != nil {
                return text
            }
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            // Markers must touch the text they enclose, so surrounding spaces stay outside.
            let leading = String(text.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\t" })

            var formatted = Self.escaped(core)
            if run.isStrikethrough {
                formatted = "~~\(formatted)~~"
            }
            switch (run.isBold, run.isItalic) {
            case (true, true): formatted = "***\(formatted)***"
            case (true, false): formatted = "**\(formatted)**"
            case (false, true): formatted = "*\(formatted)*"
            case (false, false): break
            }
            if let link = run.link {
                formatted = "[\(formatted)](\(link))"
            }
            return leading + formatted + trailing
        }.joined()
    }

    /// Escapes the characters that Markdown reads as emphasis, code, links, or HTML,
    /// so that literal text renders as it appears in the note.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_~[]<>".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// Escapes the start of a line that Markdown would read as a heading, list item,
    /// or rule, such as `# Groceries`, `+ milk`, `1. eggs`, or `---`.
    private static func escapingLineStart(_ line: Substring) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        func endsMarker(_ index: Substring.Index) -> Bool {
            index == rest.endIndex || rest[index] == " " || rest[index] == "\t"
        }
        guard let first = rest.first else { return String(line) }

        let hashes = rest.prefix { $0 == "#" }
        let isHeading = (1 ... 6).contains(hashes.count) && endsMarker(hashes.endIndex)
        let isBullet = (first == "-" || first == "+") && endsMarker(rest.index(after: rest.startIndex))
        let isRule = "-=".contains(first) && rest.allSatisfy { $0 == first || $0 == " " || $0 == "\t" }
        if isHeading || isBullet || isRule {
            return String(indent) + "\\" + rest
        }

        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if (1 ... 9).contains(digits.count), digits.endIndex < rest.endIndex,
            ".)".contains(rest[digits.endIndex]), endsMarker(rest.index(after: digits.endIndex))
        {
            return String(indent + digits) + "\\" + rest[digits.endIndex...]
        }
        return String(line)
    }
}
