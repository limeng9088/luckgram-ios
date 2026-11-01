import Foundation

/// Pure logic of spec 21 (unit-tested, Foundation only): the AI rewrites plain text, so formatting,
/// mentions by name, links and custom emoji of the original are put back afterwards. Each formatted
/// range is looked up in the result by its exact text, in the original order; a range whose text the
/// AI changed is dropped (the result then just has less formatting, like before this existed).
/// Same rule as Android `AiWritingEntities`; ranges are UTF-16 (`NSRange`).
public enum LuckgramAIWritingEntities {
    /// For each range of `original`, its new location in `result` (same length), or nil.
    public static func relocate(original: String, ranges: [NSRange], result: String) -> [Int?] {
        let source = original as NSString
        let target = result as NSString
        var out = [Int?](repeating: nil, count: ranges.count)
        let order = ranges.indices.sorted { a, b in
            if ranges[a].location != ranges[b].location {
                return ranges[a].location < ranges[b].location
            }
            return ranges[a].length > ranges[b].length
        }
        // same text at the same place may be claimed once (two "😀" must land on two different ones),
        // but different ranges may overlap (bold around a mention)
        var claimed = Set<String>()
        var cursor = 0
        for i in order {
            let range = ranges[i]
            if range.location < 0 || range.length <= 0 || range.location + range.length > source.length {
                continue
            }
            let s = source.substring(with: range)
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            guard let at = find(target, s, from: cursor, claimed: claimed) ?? find(target, s, from: 0, claimed: claimed) else {
                continue
            }
            claimed.insert("\(at):\(s)")
            out[i] = at
            cursor = at + 1
        }
        return out
    }

    private static func find(_ text: NSString, _ s: String, from: Int, claimed: Set<String>) -> Int? {
        var start = from
        while start <= text.length {
            let found = text.range(of: s, options: [.literal], range: NSRange(location: start, length: text.length - start))
            if found.location == NSNotFound {
                return nil
            }
            if !claimed.contains("\(found.location):\(s)") {
                return found.location
            }
            start = found.location + 1
        }
        return nil
    }
}
