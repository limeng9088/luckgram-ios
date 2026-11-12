import Foundation

/// Luckgram specs#145: pure rules of the WeChat-style 「按住 说话」 bar (unit-tested; keep in sync with
/// Android `LuckgramVoiceBar`).
public enum LuckgramVoiceBarLogic {
    /// Where the finger is while holding.
    public enum Zone: Equatable {
        case send
        case cancel
        case text
    }

    /// Above `actionLineY` (the top of the release area) the left half cancels and the right half
    /// converts to text; below it, releasing sends.
    public static func zone(x: Double, y: Double, width: Double, actionLineY: Double) -> Zone {
        if y >= actionLineY || width <= 0.0 {
            return .send
        }
        return x < width / 2.0 ? .cancel : .text
    }

    /// m:ss for the overlay's timer.
    public static func formatDuration(_ seconds: Double) -> String {
        let s = Int(max(0.0, seconds))
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }

    /// Holds shorter than this are dropped with 「说话时间太短」.
    public static let minimumDuration: Double = 0.7

    /// Loudest mic level (`ManagedAudioRecorder.micLevel`, peak sample / 4000) below which nothing was said at all.
    public static let silenceLevel: Double = 0.12

    public static func isSilent(peakLevel: Double) -> Bool {
        return peakLevel < silenceLevel
    }

    /// A voice stays above `silenceLevel` for a while; a click or a bump is one loud moment.
    public static let minimumLoudSeconds: Double = 0.3

    /// A gap between two level readings counts for at most this much, however late the second one comes.
    public static let loudStepLimit: Double = 0.25

    /// Adds the time since the previous level reading to the total if the input is loud now.
    public static func loudSeconds(_ total: Double, level: Double, sincePrevious: Double) -> Double {
        if level < silenceLevel {
            return total
        }
        return total + min(loudStepLimit, max(0.0, sincePrevious))
    }

    public static func isSilent(peakLevel: Double, loudSeconds: Double) -> Bool {
        return peakLevel < silenceLevel || loudSeconds < minimumLoudSeconds
    }

    /// Length (in characters, after normalizing) of the longest piece that comes twice without overlapping,
    /// provided it has at least 4 different characters (「哈哈哈哈」 is laughter, not a loop).
    static func longestRepeat(_ normalized: String) -> Int {
        let a = Array(normalized.unicodeScalars.prefix(400))
        let n = a.count
        if n < 2 {
            return 0
        }
        var best = 0
        var previous = [Int](repeating: 0, count: n + 1)
        for i in 1 ... n {
            var current = [Int](repeating: 0, count: n + 1)
            if i < n {
                for j in (i + 1) ... n {
                    if a[i - 1] == a[j - 1] && previous[j - 1] < j - i {
                        let length = previous[j - 1] + 1
                        current[j] = length
                        if length > best && Set(a[(i - length) ..< i]).count >= 4 {
                            best = length
                        }
                    }
                }
            }
            previous = current
        }
        return best
    }

    /// What speech-to-text models make up for recordings with no speech in them.
    private static let silencePhrases: Set<String> = [
        "thankyousomuchforwatching", "thankyouforwatching", "thanksforwatching", "メッセージなし", "subtitlesbytheamaraorgcommunity",
        "ご視聴ありがとうございました", "私のビデオを見てくれてありがとう", "谢谢观看", "謝謝觀看", "字幕由amaraorg社区提供"
    ]

    /// Loudest mic level below which the recording was at most faint noise: a transcript made only of filler
    /// sentences is then not believed either.
    public static let weakLevel: Double = 0.35

    public static func isWeak(peakLevel: Double) -> Bool {
        return peakLevel < weakLevel
    }

    /// Filler sentences a model strings together for near-silence (「That's it. Thank you. God bless.」). People do
    /// say these, so they only count when the recording was faint.
    private static let fillerSentences: Set<String> = [
        "thankyou", "thanks", "thankyouverymuch", "thatsit", "godbless", "bye", "byebye", "you", "ok", "okay", "yeah",
        "谢谢", "謝謝", "谢谢大家", "ありがとう", "ありがとうございました", "おやすみなさい"
    ]

    private static func normalize(_ text: String) -> String {
        return String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// The transcript is something a model invents for silence, not something that was said:
    /// a short text around a stock phrase, one sentence three times over, a loop of the same words, or (faint recording only) nothing but fillers.
    public static func isSilenceHallucination(_ text: String, weakSignal: Bool = false) -> Bool {
        let normalized = normalize(text)
        if normalized.isEmpty {
            return false
        }
        // short text built around a stock phrase (「メッセージなし。ご視聴ありがとうございました。」) counts too
        if normalized.count <= 40 && silencePhrases.contains(where: { normalized.contains($0) }) {
            return true
        }
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?。！？\n")).map(normalize).filter { !$0.isEmpty }
        var counts: [String: Int] = [:]
        for sentence in sentences {
            counts[sentence, default: 0] += 1
        }
        if counts.values.contains(where: { $0 >= 3 }) {
            return true
        }
        // a loop: 「BREATHING IN DEEPLY BREATHING OUT DEEPLY BREATHING IN DEEPLY …」, half of the text or more said twice
        let repeated = longestRepeat(normalized)
        if repeated >= 6 && repeated * 2 * 2 >= normalized.unicodeScalars.count {
            return true
        }
        return weakSignal && !sentences.isEmpty && sentences.allSatisfy { fillerSentences.contains($0) }
    }
}
