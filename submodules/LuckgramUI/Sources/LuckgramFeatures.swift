import Foundation

/// The Luckgram feature registry. Adding a feature = adding one `add(...)` line here; the
/// "Settings → Luckgram Features" page is generated from this list (rows keep the order of the
/// lines inside each group). Keep keys and defaults in sync with Android
/// (`org.telegram.luckgram.LuckgramFeatures`).
///
///     add(.toggle("quick_replies", group: .messagesLanguage, default: true,
///         title: ("快捷回复", "Quick replies"),
///         description: ("输入 / 选择常用回复", "Type / to pick a saved reply"))
///         .subpage { context in quickRepliesSettingsController(context: context) })
///
/// A feature that must ask before it is switched on (e.g. a legal notice, #58):
///
///     add(.toggle("call_recording", group: .mediaCallsStorage, default: false, …)
///         .subpage { context in callRecordingSettingsController(context: context) }
///         .confirmEnable { context, present, done in luckgramRequestEnableCallRecording(context: context, present: present, completion: done) })
///
/// Read a switch anywhere with `LuckgramSettings.shared.isEnabled("quick_replies")`
/// (or `isEnabledSignal(_:)` to follow changes).
public enum LuckgramFeatures {
    public static let debugDemo = "debug_demo"
    public static let roundVideoFromGallery = "round_video_from_gallery"

    public static let all: [LuckgramFeature] = {
        var list: [LuckgramFeature] = []
        func add(_ feature: LuckgramFeature) {
            list.append(feature)
        }

        // ---- 账号与隐私 / Accounts & Privacy

        // ---- 消息与语言 / Messages & Language
        add(.toggle("translate_out", group: .messagesLanguage, default: true,
            title: ("发送前翻译", "Translate before sending"),
            description: ("在输入框里先翻译成对方的语言再发送", "Translate your message into the other person's language before sending")))
        // Quick replies "Manage" subpage is attached by TelegramUI at startup (it lives in
        // ChatTextInputPanelNode, which depends on LuckgramUI).
        add(.toggle("quick_replies", group: .messagesLanguage, default: true,
            title: ("快捷回复", "Quick replies"),
            description: ("把常用回复存成模板，输入框里一点就填入", "Save frequent replies as templates and insert them with one tap")))

        // ---- 媒体、通话与存储 / Media, Calls & Storage
        add(.toggle(LuckgramFeatures.roundVideoFromGallery, group: .mediaCallsStorage, default: true,
            title: ("相册视频发成圆形视频", "Gallery video as round video"),
            description: ("附件菜单里选一个视频，可作为圆形视频发送", "Send a video from the gallery as a round video message")))

        // ---- 资料与整理 / Profiles & Organization

        // ---- AI

        // ---- 调试 / Debug (debug builds or unlocked debug tools only)
        add(.toggle(LuckgramFeatures.debugDemo, group: .debug, default: false,
            title: ("测试开关", "Test switch"),
            description: ("仅用于验证开关框架，不影响任何功能", "Only for testing the switch framework; changes nothing"))
            .debugOnly())

        return list
    }()

    public static func find(_ key: String) -> LuckgramFeature? {
        return all.first(where: { $0.key == key })
    }
}
