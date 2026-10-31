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

    public static let all: [LuckgramFeature] = {
        var list: [LuckgramFeature] = []
        func add(_ feature: LuckgramFeature) {
            list.append(feature)
        }

        // ---- 账号与隐私 / Accounts & Privacy

        // ---- 消息与语言 / Messages & Language

        // ---- 媒体、通话与存储 / Media, Calls & Storage

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
