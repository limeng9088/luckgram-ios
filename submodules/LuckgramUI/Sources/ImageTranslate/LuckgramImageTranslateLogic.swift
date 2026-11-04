import Foundation

/// specs#108 image translation: the rules shared with Android (`ImageTranslateLogic.java`).
/// Foundation only, so it runs in the SwiftPM unit tests on Linux.
///
/// Geometry follows the #106 OCR result: boxes normalized to 0..1, origin top-left, y down.
public enum LuckgramImageTranslateLogic {
    /// Feature switch (specs#108 需求 6), default on.
    public static let featureKey = "image_translate"
    /// Settings key of the image-only default language; empty = follow reading translation.
    public static let toLangKey = "image_translate_to_lang"
    /// Prefix of the per-chat image language, followed by the peer id.
    public static let chatKeyPrefix = "image_translate_lang."
    /// One Telegram translateText request carries at most this many characters…
    public static let maxBatchChars = 3000
    /// …and at most this many text pieces.
    public static let maxBatchItems = 20
    /// Font size bounds, in pixels of the image.
    public static let minFontPx: Double = 8.0
    /// Inset of the cover rectangle around the text, as a share of the line height.
    public static let paddingRatio: Double = 0.12
    /// Alpha (0..255) of the cover: opaque enough to hide the original text, still "semi-transparent".
    public static let coverAlpha = 235

    // MARK: Language

    /// specs#108 需求 2: this chat's image language, else the image-only default, else the reading
    /// translation language (#105), else the app language. Empty strings count as unset.
    public static func targetLanguage(perChat: String?, imageDefault: String?, readingTarget: String?, appLanguage: String?) -> String {
        for lang in [perChat, imageDefault, readingTarget, appLanguage] {
            if let value = lang?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                return value
            }
        }
        return "en"
    }

    /// Language code reduced to what decides "same language": lower case, no region; every zh-* is zh.
    public static func base(_ lang: String?) -> String {
        guard let lang else {
            return ""
        }
        let l = lang.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-")
        if let dash = l.firstIndex(of: "-"), dash != l.startIndex {
            return String(l[..<dash])
        }
        return l
    }

    /// Top bar 「日本語 → 中文 ▾」; without a known source just 「→ 中文 ▾」.
    public static func header(fromName: String?, toName: String) -> String {
        guard let fromName, !fromName.isEmpty else {
            return "→ \(toName) ▾"
        }
        return "\(fromName) → \(toName) ▾"
    }

    // MARK: Which blocks

    /// Whether a block is worth translating: it has letters (not only digits, prices, symbols) and
    /// its language, when known, differs from the target. Untranslated blocks keep the original.
    public static func shouldTranslate(text: String, blockLanguage: String?, imageLanguage: String?, targetLanguage: String) -> Bool {
        if !hasLetters(text) {
            return false
        }
        let lang = (blockLanguage?.isEmpty == false) ? blockLanguage : imageLanguage
        guard let lang, !lang.isEmpty else {
            return true
        }
        return base(lang) != base(targetLanguage)
    }

    static func hasLetters(_ text: String) -> Bool {
        return text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Splits the texts to translate into Telegram requests (`maxBatchItems` pieces, `maxBatchChars`
    /// characters each). Returns index lists into `texts`; a text longer than the limit gets its own batch.
    public static func batches(_ texts: [String]) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        var chars = 0
        for (i, text) in texts.enumerated() {
            let len = text.utf16.count
            if !current.isEmpty && (current.count >= maxBatchItems || chars + len > maxBatchChars) {
                result.append(current)
                current = []
                chars = 0
            }
            current.append(i)
            chars += len
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    // MARK: Layout

    /// Largest font size (≤ 0.9 × the original line height, ≥ `minFontPx`) at which `text` wrapped
    /// to `width` fits `height`. `measure(text, fontSize, width)` is the platform text height.
    public static func fitFontSize(text: String, width: Double, height: Double, lineHeight: Double, measure: (String, Double, Double) -> Double) -> Double {
        var hi = max(minFontPx, lineHeight * 0.9)
        var lo = minFontPx
        if measure(text, hi, width) <= height {
            return hi
        }
        if measure(text, lo, width) > height {
            return lo
        }
        while hi - lo > 0.5 {
            let mid = (lo + hi) / 2.0
            if measure(text, mid, width) <= height {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Pixel rectangle (left, top, right, bottom) of a normalized box, clamped to the image.
    public static func pixelRect(x: Double, y: Double, width: Double, height: Double, imageWidth: Int, imageHeight: Int) -> [Double] {
        func clamp(_ v: Double) -> Double { min(1.0, max(0.0, v)) }
        return [clamp(x) * Double(imageWidth), clamp(y) * Double(imageHeight), clamp(x + width) * Double(imageWidth), clamp(y + height) * Double(imageHeight)]
    }

    /// Cover rectangle: the text box grown by `paddingRatio` of a line, clamped to the image.
    public static func coverRect(_ rect: [Double], lineHeight: Double, imageWidth: Int, imageHeight: Int) -> [Double] {
        let pad = lineHeight * paddingRatio
        return [max(0.0, rect[0] - pad), max(0.0, rect[1] - pad), min(Double(imageWidth), rect[2] + pad), min(Double(imageHeight), rect[3] + pad)]
    }

    // MARK: Colors

    /// Relative luminance 0..1 of an sRGB color (0..255 channels), WCAG formula.
    public static func luminance(r: Int, g: Int, b: Int) -> Double {
        func lin(_ c: Int) -> Double {
            let s = Double(c) / 255.0
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Text on the sampled background: black on light, white on dark (whichever contrasts more).
    public static func darkText(r: Int, g: Int, b: Int) -> Bool {
        let l = luminance(r: r, g: g, b: b)
        return (l + 0.05) / 0.05 >= 1.05 / (l + 0.05)
    }

    // MARK: Hit test

    /// Index of the block under the normalized point, the smallest box when they overlap, or nil.
    /// `boxes` holds x, y, width, height per block.
    public static func hitTest(boxes: [[Double]], x: Double, y: Double) -> Int? {
        var best: Int?
        var bestArea = Double.greatestFiniteMagnitude
        for (i, b) in boxes.enumerated() where x >= b[0] && x <= b[0] + b[2] && y >= b[1] && y <= b[1] + b[3] {
            let area = b[2] * b[3]
            if area < bestArea {
                bestArea = area
                best = i
            }
        }
        return best
    }

    /// Copy text: the translated blocks in reading order (original where a block was not translated).
    public static func copyText(originals: [String], translations: [String?]) -> String {
        var pieces: [String] = []
        for (i, original) in originals.enumerated() {
            let t = i < translations.count ? translations[i] : nil
            let piece = (t?.isEmpty == false) ? t! : original
            if !piece.isEmpty {
                pieces.append(piece)
            }
        }
        return pieces.joined(separator: "\n")
    }
}
