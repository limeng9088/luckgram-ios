import Foundation

/// specs#106 (OCR) result, shared with specs#108 (image translation). Same names and meaning as
/// Android `OcrResult`:
/// - `imageWidth` / `imageHeight`: pixels of the recognized image, already upright;
/// - `language`: main language of the image as BCP-47 (e.g. "ja"), or nil if unsure;
/// - `source`: `.device` (on-device) or `.ai` (Luckgram AI fallback);
/// - `blocks`: paragraphs in reading order (top to bottom, left to right).
///
/// Coordinates are normalized to 0..1, origin top-left, x right, y down (Vision's bottom-left
/// boxes are flipped with `Box.fromBottomLeft`).
///
/// Pure (Foundation only, no other Luckgram file) so it is unit tested on its own.
public struct LuckgramOcrResult: Equatable {
    public enum Source: String, Equatable {
        case device
        case ai
    }

    /// Axis-aligned rectangle, normalized 0..1, origin top-left.
    public struct Box: Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// From pixel edges of an image of `w` x `h`; clamped to the image.
        public static func fromPixels(left: Double, top: Double, right: Double, bottom: Double, w: Int, h: Int) -> Box {
            guard w > 0, h > 0 else {
                return Box(x: 0.0, y: 0.0, width: 0.0, height: 0.0)
            }
            let l = clamp(left / Double(w)), t = clamp(top / Double(h)), r = clamp(right / Double(w)), b = clamp(bottom / Double(h))
            return Box(x: min(l, r), y: min(t, b), width: abs(r - l), height: abs(b - t))
        }

        /// From a rectangle normalized with the origin bottom-left (Vision): flips y.
        public static func fromBottomLeft(x: Double, y: Double, width: Double, height: Double) -> Box {
            return Box(x: x, y: clamp(1.0 - y - height), width: width, height: height)
        }

        public var centerY: Double {
            return self.y + self.height / 2.0
        }

        public func contains(x px: Double, y py: Double) -> Bool {
            return px >= self.x && px <= self.x + self.width && py >= self.y && py <= self.y + self.height
        }

        /// Smallest box around all of `boxes` (nil for none).
        public static func union(_ boxes: [Box]) -> Box? {
            guard !boxes.isEmpty else {
                return nil
            }
            var l = 1.0, t = 1.0, r = 0.0, b = 0.0
            for bx in boxes {
                l = min(l, bx.x)
                t = min(t, bx.y)
                r = max(r, bx.x + bx.width)
                b = max(b, bx.y + bx.height)
            }
            return Box(x: l, y: t, width: max(0.0, r - l), height: max(0.0, b - t))
        }

        static func clamp(_ v: Double) -> Double {
            return max(0.0, min(1.0, v))
        }
    }

    /// Four corners, normalized, starting top-left and going clockwise (for rotated text).
    public struct Quad: Equatable {
        public var points: [(x: Double, y: Double)]

        public init(points: [(x: Double, y: Double)]) {
            self.points = points
        }

        public static func ==(lhs: Quad, rhs: Quad) -> Bool {
            return lhs.points.count == rhs.points.count && zip(lhs.points, rhs.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
        }
    }

    public struct Line: Equatable {
        public var text: String
        public var box: Box
        public var quad: Quad?

        public init(text: String, box: Box, quad: Quad? = nil) {
            self.text = text
            self.box = box
            self.quad = quad
        }
    }

    /// A paragraph: its lines joined with "\n".
    public struct Block: Equatable {
        public var text: String
        /// BCP-47, or nil.
        public var language: String?
        public var box: Box
        public var quad: Quad?
        public var lines: [Line]

        public init(text: String, language: String?, box: Box, quad: Quad? = nil, lines: [Line]) {
            self.text = text
            self.language = LuckgramOcrResult.normalizedLanguage(language)
            self.box = box
            self.quad = quad
            self.lines = lines
        }

        /// A block made of lines; text and box come from the lines.
        public static func of(lines: [Line], language: String?) -> Block {
            return Block(text: lines.map { $0.text }.joined(separator: "\n"), language: language, box: Box.union(lines.map { $0.box }) ?? Box(x: 0.0, y: 0.0, width: 0.0, height: 0.0), lines: lines)
        }
    }

    public var imageWidth: Int
    public var imageHeight: Int
    public var language: String?
    public var source: Source
    public var blocks: [Block]

    public init(imageWidth: Int, imageHeight: Int, language: String?, source: Source, blocks: [Block]) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.language = LuckgramOcrResult.normalizedLanguage(language)
        self.source = source
        self.blocks = blocks
    }

    /// All text, blocks joined with "\n" (what "Copy all" copies).
    public var text: String {
        return self.blocks.map { $0.text }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }

    public var hasText: Bool {
        return !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The block under a tap at normalized (`x`, `y`), or nil.
    public func block(atX x: Double, y: Double) -> Block? {
        return self.blocks.first(where: { $0.box.contains(x: x, y: y) })
    }

    /// Reading order: top to bottom; blocks whose vertical centers are within half a block height of
    /// each other count as one row and go left to right.
    public static func readingOrder(_ blocks: [Block]) -> [Block] {
        let byY = blocks.sorted(by: { $0.box.centerY < $1.box.centerY })
        var out: [Block] = []
        var i = 0
        while i < byY.count {
            let first = byY[i]
            let tolerance = first.box.height / 2.0
            var row: [Block] = []
            var j = i
            while j < byY.count && abs(byY[j].box.centerY - first.box.centerY) <= tolerance {
                row.append(byY[j])
                j += 1
            }
            out.append(contentsOf: row.sorted(by: { $0.box.x < $1.box.x }))
            i = max(j, i + 1)
        }
        return out
    }

    /// Main language: the one with the most characters over the blocks that have one, or nil.
    public static func mainLanguage(_ blocks: [Block]) -> String? {
        var order: [String] = []
        var count: [String: Int] = [:]
        for b in blocks {
            guard let lang = b.language else {
                continue
            }
            if count[lang] == nil {
                order.append(lang)
            }
            count[lang, default: 0] += b.text.filter { !$0.isWhitespace }.count
        }
        var best: String?
        var bestCount = 0
        for lang in order where count[lang, default: 0] > bestCount {
            best = lang
            bestCount = count[lang, default: 0]
        }
        return best
    }

    /// Vision gives lines only: consecutive lines (in reading order) form one paragraph when the gap
    /// between them is under a line height, their left edges are close and heights similar.
    public static func paragraphs(_ lines: [Line]) -> [[Line]] {
        let ordered = lines.sorted(by: { $0.box.y < $1.box.y })
        var out: [[Line]] = []
        for line in ordered {
            if var last = out.last, let prev = last.last {
                let gap = line.box.y - (prev.box.y + prev.box.height)
                let h = max(prev.box.height, line.box.height)
                let similar = min(prev.box.height, line.box.height) >= h * 0.6
                if gap >= -h * 0.3 && gap < h * 1.0 && abs(line.box.x - prev.box.x) < max(0.04, h) && similar {
                    last.append(line)
                    out[out.count - 1] = last
                    continue
                }
            }
            out.append([line])
        }
        return out
    }

    /// Language from the script (same rules as Android `OcrLogic`): kana → "ja", hangul → "ko",
    /// Han → "zh", else nil.
    public static func scriptLanguage(_ text: String) -> String? {
        var kana = 0, hangul = 0, han = 0, latin = 0
        for u in text.unicodeScalars {
            let c = u.value
            if (0x3040...0x30FF).contains(c) || (0x31F0...0x31FF).contains(c) || (0xFF66...0xFF9D).contains(c) {
                kana += 1
            } else if (0xAC00...0xD7AF).contains(c) || (0x1100...0x11FF).contains(c) || (0x3130...0x318F).contains(c) {
                hangul += 1
            } else if (0x4E00...0x9FFF).contains(c) || (0x3400...0x4DBF).contains(c) || (0xF900...0xFAFF).contains(c) {
                han += 1
            } else if (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0xC0...0x24F).contains(c) {
                latin += 1
            }
        }
        if kana > 0 && kana * 5 >= han / 2 {
            return "ja"
        }
        if hangul > 0 && hangul >= han {
            return "ko"
        }
        if han > 0 && han * 3 >= latin {
            return "zh"
        }
        return nil
    }

    static func normalizedLanguage(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "und" else {
            return nil
        }
        return s
    }
}
