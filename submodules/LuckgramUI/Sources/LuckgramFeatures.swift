import Foundation
import LuckgramAccountsStore

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
    /// spec 18
    public static let aiAssistant = "ai_assistant"
    public static let aiAssistantRow = "ai_assistant_row"
    /// spec 22
    public static let aiAgents = "ai_agents"
    /// spec 23
    public static let aiImage = "ai_image"
    public static let roundVideoFromGallery = "round_video_from_gallery"
    /// spec 19
    public static let aiSummary = "ai_summary"

    public static let all: [LuckgramFeature] = {
        var list: [LuckgramFeature] = []
        func add(_ feature: LuckgramFeature) {
            list.append(feature)
        }

        // ---- 账号与隐私 / Accounts & Privacy
        add(.toggle(LuckgramDoubleBottom.featureKey, group: .accountPrivacy, default: false,
            title: ("双重空间", "Double space"),
            description: ("用第二个密码解锁时只显示选定的账号", "A second passcode that shows only the accounts you pick"))
            .subpage { context in luckgramDoubleBottomController(context: context) }
            .confirmEnable { context, present, done in LuckgramDoubleBottom.confirmEnable(context: context, present: present, done: done) }
            .confirmDisable { context, present, done in LuckgramDoubleBottom.confirmDisable(context: context, present: present, done: done) }
            .hiddenWhen { LuckgramDoubleBottomState.shared.isActive })
        add(.toggle(LuckgramBackup.featureKey, group: .accountPrivacy, default: true,
            title: ("账号备份", "Account backup"),
            description: ("把账号导出为加密文件，换手机后导入", "Export accounts to an encrypted file and import them on a new phone"))
            .subpage { context in luckgramBackupController(context: context) })
        add(.toggle(LuckgramStoreRestrictionsFeature.key, group: .accountPrivacy, default: false,
            title: ("受限频道", "Store-restricted channels"),
            description: ("查看只在商店版 Telegram 中被隐藏的频道和群组；点进去可调整「显示 18+ 内容」", "View channels and groups hidden only in store versions of Telegram; tap for the 18+ content setting"))
            .subpage { context in context.sharedContext.makeDataAndStorageController(context: context, sensitiveContent: true) }
            .confirmEnable { context, present, done in LuckgramStoreRestrictionsFeature.confirmEnable(context: context, present: present, done: done) })

        // ---- 消息与语言 / Messages & Language
        add(.toggle("select_all_from_sender", group: .messagesLanguage, default: true,
            title: ("全选某人的消息", "Select all from sender"),
            description: ("长按消息一次选中这个人在本聊天的全部消息", "Long-press a message to select everything its sender wrote here")))
        add(.toggle("save_to_saved", group: .messagesLanguage, default: true,
            title: ("一键收藏", "Save in one tap"),
            description: ("消息菜单里一点就存到收藏夹", "Save a message to Saved Messages straight from its menu")))
        add(.toggle("translate_out", group: .messagesLanguage, default: true,
            title: ("发送前翻译", "Translate before sending"),
            description: ("在输入框里先翻译成对方的语言再发送", "Translate your message into the other person's language before sending")))
        // Quick replies "Manage" subpage is attached by TelegramUI at startup (it lives in
        // ChatTextInputPanelNode, which depends on LuckgramUI).
        add(.toggle("quick_replies", group: .messagesLanguage, default: true,
            title: ("快捷回复", "Quick replies"),
            description: ("把常用回复存成模板，输入框里一点就填入", "Save frequent replies as templates and insert them with one tap")))

        // ---- 媒体、通话与存储 / Media, Calls & Storage
        // Settings page is attached by TelegramUI at startup (it lives in TelegramCallsUI,
        // which depends on LuckgramUI).
        add(.toggle("call_recording", group: .mediaCallsStorage, default: false,
            title: ("通话录音", "Call recording"),
            description: ("一对一通话中录音，挂断后保存到收藏夹", "Record one-on-one calls and save them to Saved Messages")))
        add(.toggle(LuckgramFeatures.roundVideoFromGallery, group: .mediaCallsStorage, default: true,
            title: ("相册视频发成圆形视频", "Gallery video as round video"),
            description: ("附件菜单里选一个视频，可作为圆形视频发送", "Send a video from the gallery as a round video message")))

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
        add(.toggle(LuckgramHiddenChats.featureKey, group: .profileOrganize, default: true,
            title: ("隐藏聊天", "Hidden chats"),
            description: ("把聊天从列表里藏起来，下拉列表找回", "Hide chats from the list; pull down to find them"))
            .subpage { context in luckgramHiddenChatsSettingsController(context: context) })

        // ---- AI
        add(.toggle(LuckgramFeatures.aiAssistant, group: .ai, default: true,
            title: ("AI 助手", "AI assistant"),
            description: ("聊天列表顶部的「AI」按钮：提问、总结、改写、讲解、解题", "The \"AI\" button on the chat list: ask, summarize, rewrite, explain, solve")))
        add(.toggle(LuckgramFeatures.aiImage, group: .ai, default: true,
            title: ("AI 画图", "AI images"),
            description: ("在 AI 助手里描述画面生成图片，可发送、保存、重画", "Describe a picture in the AI assistant; send, save or redraw it")))
        add(.toggle(LuckgramFeatures.aiAgents, group: .ai, default: true,
            title: ("AI 智能体", "AI agents"),
            description: ("AI 助手里的旅行规划师、文案写手等，也能自己创建", "Travel planner, copywriter and more in the AI assistant, or make your own")))
        add(.toggle(LuckgramFeatures.aiAssistantRow, group: .ai, default: true,
            title: ("聊天列表置顶「Luckgram AI」", "Pin \"Luckgram AI\" in the chat list"),
            description: ("在聊天列表顶部显示一行 AI 助手入口", "Show an AI assistant row at the top of the chat list")))
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
        add(.toggle(LuckgramFeatures.aiSummary, group: .ai, default: true,
            title: ("聊天总结", "Chat summary"),
            description: ("未读多时一键总结要点，点引用跳回原消息，还能就这些消息提问", "Summarize many unread messages, jump to the source, ask about them")))

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
