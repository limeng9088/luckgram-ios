import Foundation
import TelegramPresentationData

/// Luckgram: send a gallery video as a round video message (spec 03-round-video).
///
/// Switch key `round_video_from_gallery`, default on. Until the shared `LuckgramSettings`
/// framework (spec 00) lands, the value is read from the standard user defaults under
/// `luckgram.round_video_from_gallery` (device-wide), so wiring it into `LuckgramSettings`
/// later only touches `isEnabled`.
public enum LuckgramRoundVideo {
    public static let key = "round_video_from_gallery"
    public static let defaultValue = true
    /// Longest round video Telegram accepts, seconds.
    public static let maxDuration: Double = 60.0

    private static var defaultsKey: String {
        return "luckgram." + key
    }

    public static var isEnabled: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber {
                return value.boolValue
            }
            return defaultValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
        }
    }

    public enum StringKey: Int {
        case sendAsRound
        case title
        case cancel
        case send
        case hint
        case converting
        case failed
        case selected
    }

    private static let en: [StringKey: String] = [
        .sendAsRound: "Send as Round Video",
        .title: "Round Video",
        .cancel: "Cancel",
        .send: "Send",
        .hint: "Drag to move, pinch to zoom",
        .converting: "Converting… %d%%",
        .failed: "Couldn't convert this video.",
        .selected: "Selected %@"
    ]

    private static let zh: [StringKey: String] = [
        .sendAsRound: "作为圆形视频发送",
        .title: "圆形视频",
        .cancel: "取消",
        .send: "发送",
        .hint: "拖动调整位置，双指缩放",
        .converting: "正在转换… %d%%",
        .failed: "无法转换这个视频。",
        .selected: "已选 %@"
    ]

    public static func isChinese(_ strings: PresentationStrings?) -> Bool {
        if let strings {
            let code = strings.baseLanguageCode.lowercased()
            if code.hasPrefix("zh") {
                return true
            }
            if code != "en" {
                return false
            }
        }
        // Telegram has no built-in Chinese localization: on a Chinese system it falls back to
        // English, in which case follow the system language.
        if let preferred = Locale.preferredLanguages.first?.lowercased() {
            return preferred.hasPrefix("zh")
        }
        return false
    }

    public static func string(_ key: StringKey, _ strings: PresentationStrings?) -> String {
        let table = isChinese(strings) ? zh : en
        return table[key] ?? (en[key] ?? "")
    }
}
