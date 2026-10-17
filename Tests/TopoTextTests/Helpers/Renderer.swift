import Foundation
import TopoText

// This file imports TopoText without `@testable`, so it can use only the public API.
// It ports iMCP's `NoteRenderer` and `NoteAttachment.text(for:attachment:format:attachmentText:)`
// onto the content model, which shows that the model carries everything they use.

/// Renders note contents as Markdown or plain text, as iMCP does.
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
                paragraph.runs.map(plainText).joined().replacingOccurrences(of: "\u{2028}", with: "\n")
            }.joined(separator: "\n")
        case .markdown:
            return markdown(content.paragraphs)
        }
    }

    /// The text that stands in for an attachment.
    func text(for attachment: Note.Attachment) -> String {
        switch attachment.kind {
        case .hashtag, .mention, .noteLink, .calculation, .inlineText:
            let text = attachment.displayText ?? ""
            if format == .markdown, attachment.kind == .noteLink, let target = attachment.tokenIdentifier, !text.isEmpty {
                return "[\(text)](\(target))"
            }
            return text
        case .table:
            guard let table = attachment.table else {
                return attachment.summary ?? "[Table]"
            }
            return render(table)
        case .webLink where attachment.url != nil:
            let url = attachment.url!.absoluteString
            switch format {
            case .markdown: return "[\(attachment.title ?? url)](\(url))"
            case .plain: return attachment.title.map { "\($0) (\(url))" } ?? url
            }
        default:
            let label: String
            switch attachment.kind {
            case .drawing: label = "Drawing"
            case .scannedDocument: label = "Scanned document"
            case .image: label = "Image"
            case .pdf: label = "PDF"
            case .audio: label = "Audio"
            case .video: label = "Video"
            case .contact: label = "Contact"
            default: label = "Attachment"
            }
            if let name = attachment.title ?? attachment.fileName {
                return "[\(label): \(name)]"
            }
            return "[\(label)]"
        }
    }

    private func plainText(_ run: Note.TextRun) -> String {
        if let attachment = run.attachment {
            return text(for: attachment)
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

        func emit(_ block: Block, _ text: String) {
            guard !text.isEmpty else {
                lines.append("")
                return
            }
            if let lastBlock, lastBlock != block || [.heading, .code, .table].contains(block), lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append(text)
            lastBlock = block
        }

        func emitCode() {
            guard !code.isEmpty else { return }
            let text = code.joined(separator: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
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
                code.append(paragraph.runs.map(plainText).joined())
                continue
            }
            emitCode()

            if paragraph.runs.count == 1, let attachment = paragraph.runs[0].attachment, attachment.kind == .table {
                numbers = [:]
                emit(.table, text(for: attachment))
                continue
            }

            let indent = style.indent
            if style.kind == .numberedList {
                numbers = numbers.filter { $0.key <= indent }
            } else {
                numbers = numbers.filter { style.kind.isList && $0.key < indent }
            }

            let content = inlineMarkdown(paragraph.runs)
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
            emit(style.isBlockQuote ? .quote : block, prefix + content.replacingOccurrences(of: "\u{2028}", with: lineBreak))
        }
        emitCode()
        return lines.joined(separator: "\n")
    }

    private func inlineMarkdown(_ runs: [Note.TextRun]) -> String {
        // Neighboring runs with the same formatting merge, so that markers aren't closed and reopened.
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
            let leading = String(text.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\t" })

            var formatted = core
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
                    $0.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: "<br>")
                }
                return "| " + cells.joined(separator: " | ") + " |"
            }
            return ([line(header), line(header.map { _ in "---" })] + rows.dropFirst().map(line)).joined(separator: "\n")
        }
    }
}
