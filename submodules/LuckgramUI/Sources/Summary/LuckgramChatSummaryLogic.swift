import Foundation

/// spec 19, the same rules as Android's `ChatSummaryLogic`: the transcript sent to the model,
/// splitting long ranges into parts that fit `ai.max_input_chars`, and parsing the `[#123]`
/// message references the model puts after each point.
public enum LuckgramChatSummaryLogic {
    public struct Line {
        public let id: Int32
        public let sender: String
        public let time: String
        public let text: String

        func format() -> String {
            let flat = self.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return "[#\(self.id)] \(self.sender) (\(self.time)): \(flat)"
        }
    }

    public enum Segment: Equatable {
        case text(String)
        case reference(Int32)
    }

    /// How references must look; added to every request (the server's prompt doesn't ask for them).
    static let citeRule = "After each point, cite the message IDs it is based on, like [#123] or [#123, #456]. Use only IDs that appear in the messages."
    static let maxLineChars = 2000

    static func header(merge: Bool) -> String {
        if merge {
            return "These are summaries of consecutive parts of one chat. Merge them into 3 to 8 bullet points, keeping the [#ID] citations.\n" + citeRule + "\n\n"
        }
        return "Summarize these chat messages.\n" + citeRule + "\n\nMessages (oldest first):\n"
    }

    static func cut(_ s: String) -> String {
        if s.count > self.maxLineChars {
            return String(s.prefix(self.maxLineChars)) + "…"
        }
        return s
    }

    /// Splits the lines (oldest first) into transcripts of at most `maxChars` code points each.
    static func split(_ lines: [Line], maxChars: Int) -> [String] {
        let header = self.header(merge: false)
        let budget = max(1000, maxChars - header.unicodeScalars.count - 200)
        var parts: [String] = []
        var current = ""
        var currentLength = 0
        for line in lines {
            let s = self.cut(line.format())
            let length = s.unicodeScalars.count
            if currentLength > 0 && currentLength + length + 1 > budget {
                parts.append(header + current)
                current = ""
                currentLength = 0
            }
            if currentLength > 0 {
                current += "\n"
                currentLength += 1
            }
            current += s
            currentLength += length
        }
        if currentLength > 0 {
            parts.append(header + current)
        }
        return parts
    }

    private static let citation = try! NSRegularExpression(pattern: "[\\[（(]\\s*#?\\d+(?:\\s*[,，、]\\s*#?\\d+)*\\s*[\\]）)]")
    private static let number = try! NSRegularExpression(pattern: "\\d+")

    /// Splits `text` into plain text and references; references to IDs not in `validIds` are dropped
    /// (spec 19 需求 3: the client checks the ID is really in the range).
    static func parse(_ text: String, validIds: Set<Int32>) -> [Segment] {
        var out: [Segment] = []
        let ns = text as NSString
        var last = 0
        for match in self.citation.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            if !token.contains("#") && !token.hasPrefix("[") {
                continue // "(2024)" in normal text is not a citation
            }
            var ids: [Int32] = []
            for n in self.number.matches(in: token, range: NSRange(location: 0, length: (token as NSString).length)) {
                if let id = Int32((token as NSString).substring(with: n.range)), validIds.contains(id), !ids.contains(id) {
                    ids.append(id)
                }
            }
            if ids.isEmpty && !token.contains("#") {
                continue // e.g. "[1]" that is not one of our IDs: keep the text
            }
            var before = ns.substring(with: NSRange(location: last, length: match.range.location - last))
            while before.hasSuffix(" ") {
                before.removeLast()
            }
            if !before.isEmpty {
                out.append(.text(before))
            }
            for id in ids {
                out.append(.reference(id))
            }
            last = match.range.location + match.range.length
        }
        if last < ns.length {
            out.append(.text(ns.substring(from: last)))
        }
        return out
    }

    /// The bullet points of a summary, without their "- " / "• " / "1. " markers.
    static func bullets(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if let range = line.range(of: "^\\d{1,2}[.)、]\\s*", options: .regularExpression) {
                line = String(line[range.upperBound...])
            } else if !out.isEmpty {
                out[out.count - 1] += " " + line
                continue
            }
            if !line.isEmpty {
                out.append(line)
            }
        }
        return out
    }
}
