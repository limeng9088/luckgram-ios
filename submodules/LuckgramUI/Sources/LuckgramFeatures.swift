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
    /// spec 17
    public static let freeTranscribe = "free_transcribe"
    public static let dictation = "dictation"
    public static let dictationAITidy = "dictation_ai_tidy"
    /// spec 21
    public static let aiWriting = "ai_writing"

    public static let all: [LuckgramFeature] = {
        var list: [LuckgramFeature] = []
        func add(_ feature: LuckgramFeature) {
            list.append(feature)
        }

        // ---- 账号与隐私 / Accounts & Privacy

        // ---- 消息与语言 / Messages & Language

        // ---- 媒体、通话与存储 / Media, Calls & Storage

        // ---- 资料与整理 / Profiles & Organization

        // ---- AI
        add(.toggle(LuckgramFeatures.aiWriting, group: .ai, default: true,
            title: ("AI 写作", "AI writing"),
            description: ("输入框里的 ✦ 按钮：润色、更正式、更友好、更简短、修正语法", "The ✦ button in the message field: polish, formal, friendly, shorter, grammar")))
        add(.toggle(LuckgramFeatures.freeTranscribe, group: .ai, default: true,
            title: ("免费语音转文字", "Free voice-to-text"),
            description: ("不需要会员，把语音消息和圆形视频转成文字", "Transcribe voice and video messages without Premium")))
        add(.toggle(LuckgramFeatures.dictation, group: .ai, default: true,
            title: ("语音输入", "Voice input"),
            description: ("输入框旁的按钮，说话即可输入文字", "A button in the message field to type by speaking")))
        add(.toggle(LuckgramFeatures.dictationAITidy, group: .ai, default: false,
            title: ("语音输入 AI 整理", "Tidy voice input with AI"),
            description: ("去掉口头禅、补全标点，语言不变", "Remove filler words and add punctuation, same language")))

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
