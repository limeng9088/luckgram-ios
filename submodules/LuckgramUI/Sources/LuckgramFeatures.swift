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
    /// spec 20
    public static let aiReply = "ai_reply"
    /// spec 24
    public static let aiPost = "ai_post"

    public static let all: [LuckgramFeature] = {
        var list: [LuckgramFeature] = []
        func add(_ feature: LuckgramFeature) {
            list.append(feature)
        }

        // ---- 账号与隐私 / Accounts & Privacy

        // ---- 消息与语言 / Messages & Language
        add(.toggle("select_all_from_sender", group: .messagesLanguage, default: true,
            title: ("全选某人的消息", "Select all from sender"),
            description: ("长按消息一次选中这个人在本聊天的全部消息", "Long-press a message to select everything its sender wrote here")))
        add(.toggle("save_to_saved", group: .messagesLanguage, default: true,
            title: ("一键收藏", "Save in one tap"),
            description: ("消息菜单里一点就存到收藏夹", "Save a message to Saved Messages straight from its menu")))

        // ---- 媒体、通话与存储 / Media, Calls & Storage
        // Settings page is attached by TelegramUI at startup (it lives in TelegramCallsUI,
        // which depends on LuckgramUI).
        add(.toggle("call_recording", group: .mediaCallsStorage, default: false,
            title: ("通话录音", "Call recording"),
            description: ("一对一通话中录音，挂断后保存到收藏夹", "Record one-on-one calls and save them to Saved Messages")))

        // ---- 资料与整理 / Profiles & Organization
        // The "All notes" subpage lives in LuckgramUserNotes (which depends on this module);
        // TelegramUI attaches it at startup (SharedAccountContext).
        add(.toggle("user_notes", group: .profileOrganize, default: true,
            title: ("私人备注", "Private notes"),
            description: ("给联系人、群组和频道写只有自己能看到的备注", "Notes about contacts, groups and channels that only you can see")))
        add(.toggle("keyword_folders", group: .profileOrganize, default: true,
            title: ("关键词文件夹", "Keyword folders"),
            description: ("按关键词自动归类聊天（只在本机）", "Group chats by keyword (this device only)")))
        add(.toggle("profile_details", group: .profileOrganize, default: true,
            title: ("资料详情", "Profile details"),
            description: ("资料页显示 ID、大致注册时间，简介里的链接可以点开", "Show ID and approximate registration date; links in bios are clickable")))
        add(.toggle("shared_activity", group: .profileOrganize, default: true,
            title: ("共同群动态", "Activity in shared groups"),
            description: ("用户资料页显示对方最近在共同群组里发的消息", "Show a user's recent messages in your groups in common on their profile")))

        // ---- AI
        add(.toggle(LuckgramFeatures.aiWriting, group: .ai, default: true,
            title: ("AI 写作", "AI writing"),
            description: ("输入框里的 ✦ 按钮：润色、更正式、更友好、更简短、修正语法", "The ✦ button in the message field: polish, formal, friendly, shorter, grammar")))
        add(.toggle(LuckgramFeatures.aiPost, group: .ai, default: true,
            title: ("AI 写帖子", "AI posts"),
            description: ("有发帖权限的频道里，✦ 菜单的「写帖子」：按频道风格生成帖子", "\"Write a post\" in the ✦ menu of channels you can post in, in the channel's style")))
        add(.toggle(LuckgramFeatures.aiReply, group: .ai, default: true,
            title: ("AI 回复", "AI reply"),
            description: ("✦ 菜单里的「帮我回复」：根据对话和草稿给出 3 条候选", "\"Help me reply\" in the ✦ menu: 3 suggestions from the chat and your draft")))
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
