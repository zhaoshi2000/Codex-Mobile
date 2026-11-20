import Foundation

enum ChatBlock: Equatable {
    case text(String), code(String), table([[String]])
}

enum ChatMarkdown {
    // Keep adjacent paragraphs in one selectable surface. Code and tables retain
    // their own scrolling/copy controls and must not turn into prose.
    static func selectionBlocks(_ text: String) -> [ChatBlock] {
        var result: [ChatBlock] = []
        for block in blocks(text) {
            if case .text(let value) = block, case .text(let previous) = result.last {
                result[result.count - 1] = .text(previous + "\n\n" + value)
            } else { result.append(block) }
        }
        return result
    }
    static func cells(_ line: String) -> [String] {
        var parts: [String] = [], cell = "", escaped = false, code = false
        for c in line.trimmingCharacters(in: .whitespaces) {
            if escaped { cell.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "`" { code.toggle() }
            if c == "|" && !code { parts.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" } else { cell.append(c) }
        }
        parts.append(cell.trimmingCharacters(in: .whitespaces))
        if parts.first == "" { parts.removeFirst() }; if parts.last == "" { parts.removeLast() }
        return parts
    }
    static func blocks(_ text: String) -> [ChatBlock] {
        let lines = text.components(separatedBy: "\n")
        var result: [ChatBlock] = [], paragraph: [String] = [], i = 0
        func flush() { if !paragraph.isEmpty { result.append(.text(paragraph.joined(separator: "\n"))); paragraph = [] } }
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                flush(); i += 1; var code: [String] = []
                while i < lines.count && !lines[i].hasPrefix("```") { code.append(lines[i]); i += 1 }
                result.append(.code(code.joined(separator: "\n"))); i += 1; continue
            }
            if i + 1 < lines.count && line.contains("|") {
                let separators = cells(lines[i + 1])
                if !separators.isEmpty && separators.count == cells(line).count && separators.allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) {
                    flush(); var rows = [cells(line)]; i += 2
                    while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(cells(lines[i])); i += 1 }
                    result.append(.table(rows)); continue
                }
            }
            if line.isEmpty { flush() } else { paragraph.append(line) }; i += 1
        }
        flush(); return result
    }
    // Markdown links to PC paths need a URL scheme on iOS, not a local file:// URL.
    static func links(_ text: String) -> String {
        let pattern = #"\]\((?:<([^>]+)>|([^\s)]+))\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let capture = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let range = Range(capture, in: text), let all = Range(match.range, in: result) else { continue }
            let target = String(text[range])
            if target.hasPrefix("/") || target.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
                let encoded = Data(target.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                result.replaceSubrange(all, with: "](ifilepc://download/" + encoded + ")")
            }
        }
        return result
    }
}
