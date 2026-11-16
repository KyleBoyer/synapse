import Foundation

/// The block structure of the Markdown chat models write. Inline styling (bold, italics, inline code, links) stays in
/// each block's text for the renderer; this only splits lines into blocks.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `marker` is "•" for unordered items, or "3." for ordered ones; `depth` counts two-space indents.
    case listItem(marker: String, text: String, depth: Int)
    case code(language: String?, text: String)
    case quote(String)
    case rule

    /// Parses complete or still-streaming text; an unclosed code fence runs to the end.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: (language: String?, lines: [String])?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    code = (lang.isEmpty ? nil : lang, [])
                }
                continue
            }
            if code != nil { code?.lines.append(raw); continue }
            if line.isEmpty { flush(); continue }

            if let h = heading(line) { flush(); blocks.append(h); continue }
            if line.count >= 3, Set(line.replacingOccurrences(of: " ", with: "")).count == 1, "-*_".contains(line.first!) {
                flush(); blocks.append(.rule); continue
            }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if let item = listItem(raw) { flush(); blocks.append(item); continue }
            if !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        if let open = code { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ raw: String) -> MarkdownBlock? {
        let indent = raw.prefix { $0 == " " }.count
        let line = raw.dropFirst(indent)
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return .listItem(marker: "•", text: String(line.dropFirst(2)), depth: indent / 2)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") {
            return .listItem(marker: "\(digits).", text: String(line.dropFirst(digits.count + 2)), depth: indent / 2)
        }
        return nil
    }
}
