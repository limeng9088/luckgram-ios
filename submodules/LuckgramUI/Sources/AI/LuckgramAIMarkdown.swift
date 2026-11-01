import Foundation
import UIKit

/// Minimal Markdown for AI replies (spec 18 需求 4), the same rules as Android's
/// `LuckgramAiMarkdown`: code blocks (```), headings (#), bullet lists, **bold**, *italic* /
/// _italic_, `inline code`, ~~strike~~ and [links](url). Unclosed markers are left as they are, so
/// half-streamed text renders sensibly.
public enum LuckgramAIMarkdown {
    public enum Style: Equatable {
        case bold
        case italic
        case code
        case codeBlock(language: String)
        case link(String)
        case heading(level: Int)
        case strike
    }

    public struct Span: Equatable {
        public let style: Style
        /// Range in UTF-16 units of `Result.text`.
        public let range: NSRange
    }

    public struct Result {
        public let text: String
        public let spans: [Span]
    }

    public static func parse(_ markdown: String) -> Result {
        let out = NSMutableString()
        var spans: [Span] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.count {
                    if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        closed = true
                        break
                    }
                    code.append(lines[j])
                    j += 1
                }
                let start = out.length
                out.append(code.joined(separator: "\n"))
                spans.append(Span(style: .codeBlock(language: language), range: NSRange(location: start, length: out.length - start)))
                i = closed ? j + 1 : j
                if i < lines.count {
                    out.append("\n")
                }
                continue
            }
            var level = 0
            for c in trimmed {
                if c == "#" && level < 6 {
                    level += 1
                } else {
                    break
                }
            }
            let chars = Array(trimmed)
            if level > 0 && level < chars.count && chars[level] == " " {
                let start = out.length
                inline(String(chars[(level + 1)...]).trimmingCharacters(in: .whitespaces), out, &spans)
                spans.append(Span(style: .heading(level: level), range: NSRange(location: start, length: out.length - start)))
            } else if chars.count > 2 && (chars[0] == "-" || chars[0] == "*" || chars[0] == "+") && chars[1] == " " {
                let indent = line.prefix(while: { $0 == " " }).count
                out.append(String(repeating: "  ", count: indent / 2))
                out.append("• ")
                inline(String(chars[2...]).trimmingCharacters(in: .whitespaces), out, &spans)
            } else {
                inline(line, out, &spans)
            }
            i += 1
            if i < lines.count {
                out.append("\n")
            }
        }
        return Result(text: out as String, spans: spans)
    }

    private static func inline(_ s: String, _ out: NSMutableString, _ spans: inout [Span]) {
        let c = Array(s)
        let n = c.count
        func find(_ marker: [Character], from: Int) -> Int? {
            if marker.isEmpty || from > n - marker.count {
                return nil
            }
            var k = from
            while k <= n - marker.count {
                if Array(c[k ..< k + marker.count]) == marker {
                    return k
                }
                k += 1
            }
            return nil
        }
        func isWord(_ ch: Character) -> Bool {
            return ch.isLetter || ch.isNumber
        }
        var i = 0
        while i < n {
            let ch = c[i]
            if ch == "\\", i + 1 < n, "\\`*_~[]()#".contains(c[i + 1]) {
                out.append(String(c[i + 1]))
                i += 2
                continue
            }
            if ch == "`", let end = find(["`"], from: i + 1), end > i + 1 {
                let start = out.length
                out.append(String(c[(i + 1) ..< end]))
                spans.append(Span(style: .code, range: NSRange(location: start, length: out.length - start)))
                i = end + 1
                continue
            }
            if i + 1 < n, (ch == "*" && c[i + 1] == "*") || (ch == "_" && c[i + 1] == "_"), let end = find([ch, ch], from: i + 2), end > i + 2 {
                let start = out.length
                inline(String(c[(i + 2) ..< end]), out, &spans)
                spans.append(Span(style: .bold, range: NSRange(location: start, length: out.length - start)))
                i = end + 2
                continue
            }
            if i + 1 < n, ch == "~", c[i + 1] == "~", let end = find(["~", "~"], from: i + 2), end > i + 2 {
                let start = out.length
                inline(String(c[(i + 2) ..< end]), out, &spans)
                spans.append(Span(style: .strike, range: NSRange(location: start, length: out.length - start)))
                i = end + 2
                continue
            }
            if (ch == "*" || ch == "_"), i + 1 < n, c[i + 1] != " ", c[i + 1] != ch, (ch == "*" || i == 0 || !isWord(c[i - 1])),
               let end = find([ch], from: i + 1), end > i + 1, c[end - 1] != " ", (ch == "*" || end + 1 >= n || !isWord(c[end + 1])) {
                let start = out.length
                inline(String(c[(i + 1) ..< end]), out, &spans)
                spans.append(Span(style: .italic, range: NSRange(location: start, length: out.length - start)))
                i = end + 1
                continue
            }
            if ch == "[", let close = find(["]", "("], from: i + 1), close > i + 1, let paren = find([")"], from: close + 2), paren > close + 2 {
                let url = String(c[(close + 2) ..< paren]).trimmingCharacters(in: .whitespaces)
                if url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("tg://") {
                    let start = out.length
                    inline(String(c[(i + 1) ..< close]), out, &spans)
                    spans.append(Span(style: .link(url), range: NSRange(location: start, length: out.length - start)))
                    i = paren + 1
                    continue
                }
            }
            out.append(String(ch))
            i += 1
        }
    }

    /// Styled text for a bubble.
    public static func attributedString(_ markdown: String, font: UIFont, textColor: UIColor, linkColor: UIColor) -> NSAttributedString {
        let result = self.parse(markdown)
        let string = NSMutableAttributedString(string: result.text, attributes: [.font: font, .foregroundColor: textColor])
        let mono = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
        let codeBackground = textColor.withAlphaComponent(0.12)
        for span in result.spans where span.range.length > 0 && span.range.location + span.range.length <= string.length {
            switch span.style {
            case .bold:
                string.addAttribute(.font, value: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold), range: span.range)
            case .italic:
                string.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: font.pointSize), range: span.range)
            case .strike:
                string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .code, .codeBlock:
                string.addAttribute(.font, value: mono, range: span.range)
                string.addAttribute(.backgroundColor, value: codeBackground, range: span.range)
            case let .heading(level):
                let scale: CGFloat = level == 1 ? 1.25 : (level == 2 ? 1.15 : 1.05)
                string.addAttribute(.font, value: UIFont.systemFont(ofSize: font.pointSize * scale, weight: .bold), range: span.range)
            case let .link(url):
                if let url = URL(string: url) {
                    string.addAttribute(.link, value: url, range: span.range)
                    string.addAttribute(.foregroundColor, value: linkColor, range: span.range)
                }
            }
        }
        return string
    }
}
