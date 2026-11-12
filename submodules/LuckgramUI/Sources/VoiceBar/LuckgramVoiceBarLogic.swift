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
}
