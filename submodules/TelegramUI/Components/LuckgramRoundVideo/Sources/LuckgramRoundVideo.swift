import Foundation
import TelegramPresentationData
import LuckgramUI

/// Luckgram: send a gallery video as a round video message (spec 03-round-video).
///
/// The switch `round_video_from_gallery` is registered in `LuckgramFeatures` (group "媒体、通话与存储",
/// default on) and read through `LuckgramSettings`, which also applies the remote switch (S4).
public enum LuckgramRoundVideo {
    public static let key = LuckgramFeatures.roundVideoFromGallery
    /// Longest round video Telegram accepts, seconds.
    public static let maxDuration: Double = LuckgramRoundVideoGeometry.maxDuration

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(key)
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

    /// The one Luckgram language rule (00, issue #42).
    public static func isChinese(_ strings: PresentationStrings?) -> Bool {
        return LuckgramStrings.isChinese
    }

    public static func string(_ key: StringKey, _ strings: PresentationStrings?) -> String {
        let table = isChinese(strings) ? zh : en
        return table[key] ?? (en[key] ?? "")
    }
}
