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

    /// What speech-to-text models make up for recordings with no speech in them.
    private static let silencePhrases: Set<String> = [
        "thankyousomuchforwatching", "thankyouforwatching", "thanksforwatching", "メッセージなし", "subtitlesbytheamaraorgcommunity",
        "ご視聴ありがとうございました", "私のビデオを見てくれてありがとう", "谢谢观看", "謝謝觀看", "字幕由amaraorg社区提供"
    ]

    /// The transcript is one of the stock phrases a model invents for silence, not something that was said.
    public static func isSilenceHallucination(_ text: String) -> Bool {
        let normalized = String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        // short text built around a stock phrase (「メッセージなし。ご視聴ありがとうございました。」) counts too
        return normalized.count <= 40 && silencePhrases.contains(where: { normalized.contains($0) })
    }
}
