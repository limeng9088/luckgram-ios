import Foundation

/// specs#76: first-launch welcome page, privacy policy confirmation and the step-by-step onboarding
/// before login. When they show, which feature switches each step writes, and their texts (same
/// wording as Android `WelcomeLogic`). Foundation only, unit tested on Linux.
public enum LuckgramWelcomeLogic {
    /// Remote config key of the privacy policy page; `privacyURL` picks a default by language.
    public static let privacyURLKey = "app.privacy_url"
    public static let defaultPrivacyURLZh = "https://luckgram.cc/privacy-policy/"
    public static let defaultPrivacyURLEn = "https://luckgram.cc/en/privacy-policy/"
    /// LuckgramSettings key: the user tapped Continue in the privacy dialog on this device.
    public static let acceptedKey = "privacy_policy_accepted"
    /// Remote config key: privacy policy version; raising it asks logged-in users once more (specs#78).
    public static let privacyVersionKey = "app.privacy_version"
    /// LuckgramSettings keys: when (epoch ms) and which policy version the user agreed to.
    public static let acceptedAtKey = "privacy_policy_accepted_at"
    public static let acceptedVersionKey = "privacy_policy_version"
    /// LuckgramSettings key: the onboarding steps were gone through once; Get Started then goes to login.
    public static let onboardedKey = "onboarding_done"
    /// LuckgramSettings key: "Subscribe" on the Pro step; the Pro page opens after login (payment needs it).
    public static let openProAfterLoginKey = "onboarding_open_pro"

    // Feature switches the steps write.
    public static let keyTranslateOut = "translate_out"
    public static let keyQuickReplies = "quick_replies"
    public static let keyAIReply = "ai_reply"
    public static let keyAIWriting = "ai_writing"
    public static let keyAIAgents = "ai_agents"

    public enum Step: CaseIterable {
        /// 01 translate before sending, 02 quick replies, 20/21 AI reply and writing.
        case ai
        /// 22 AI agents.
        case agents
        /// 19 chat summary.
        case summary
        /// 25 people nearby + 26 square.
        case discover
        /// S7 Luckgram Pro: always the last step; "Coming soon" while billing is off.
        case pro
    }

    /// The welcome page replaces Telegram's splash only while no account is logged in: never for
    /// users who already have an account (upgrade), and adding a second account goes straight to login.
    public static func shouldShowWelcome(otherAccounts: Int) -> Bool {
        return otherAccounts <= 0
    }

    /// The privacy dialog opens on its own until the user has tapped Continue once.
    public static func shouldAskPrivacy(accepted: Bool) -> Bool {
        return !accepted
    }

    /// specs#78: a logged-in user is asked again ("privacy policy updated") when the remote policy
    /// version is newer than the one they agreed to. Version 0 (default) never asks.
    public static func shouldPromptUpdate(loggedIn: Bool, remoteVersion: Int, acceptedVersion: Int) -> Bool {
        return loggedIn && remoteVersion > 0 && remoteVersion > acceptedVersion
    }

    /// The onboarding steps run once; later Get Started goes straight to login.
    public static func shouldShowSteps(onboarded: Bool) -> Bool {
        return !onboarded
    }

    /// The configured privacy URL if it is https, else the default page in the app's language.
    public static func privacyURL(_ configured: String?, zh: Bool) -> String {
        let value = (configured ?? "").trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("https://") {
            return value
        }
        return zh ? defaultPrivacyURLZh : defaultPrivacyURLEn
    }

    /// The steps shown, in order; the Pro page is always the last one (user decision 2026-11-02).
    public static func steps() -> [Step] {
        return [.ai, .agents, .summary, .discover, .pro]
    }

    /// Whether the Pro step's subscribe button works. With billing off it shows "Coming soon",
    /// disabled; only "not now" can be tapped and nothing is requested from the server.
    public static func canSubscribe(_ step: Step, billingEnabled: Bool) -> Bool {
        return step == .pro && billingEnabled
    }

    /// "n/N" over the steps actually shown; `index` is 0-based.
    public static func progress(index: Int, total: Int) -> String {
        return "\(index + 1)/\(total)"
    }

    /// Fraction of the progress bar for step `index` (0-based), in (0, 1].
    public static func progressFraction(index: Int, total: Int) -> Double {
        if total <= 0 {
            return 1.0
        }
        return min(1.0, Double(index + 1) / Double(total))
    }

    /// Feature switches written by the step's two buttons ("turn on" = true, "not now" = false).
    public static func toggles(_ step: Step) -> [String] {
        switch step {
        case .ai:
            return [keyTranslateOut, keyQuickReplies, keyAIReply, keyAIWriting]
        case .agents:
            return [keyAIAgents]
        default:
            return []
        }
    }

    /// Whether the step has a "not now" choice (steps with switches, and Pro).
    public static func hasSecondary(_ step: Step) -> Bool {
        return step == .ai || step == .agents || step == .pro
    }

    public struct Texts {
        public let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        private func t(_ zh: String, _ en: String) -> String {
            return self.zh ? zh : en
        }

        // MARK: Welcome page

        public var welcomeTo: String { t("欢迎使用", "Welcome to") }
        public var appName: String { "Luckgram" }
        public var intro: String {
            t("基于 Telegram 的开源客户端：AI 帮你写、帮你回、帮你总结，还有隐藏聊天、附近的人和广场。",
              "An open-source Telegram client with AI that writes, replies and sums up for you, plus hidden chats, people nearby and the Square.")
        }
        public var getStarted: String { t("开始使用", "Get Started") }

        // MARK: Privacy dialog

        public var privacyTitle: String { t("Luckgram 隐私政策", "Luckgram Privacy Policy") }
        public var privacyText: String {
            t("Luckgram 是非官方的 Telegram 客户端，你在 Luckgram 里用到的很多服务实际由 Telegram 提供。\n\n使用前请先阅读我们的隐私政策。\n\n点击「继续」即表示你已阅读并同意 Luckgram 隐私政策。",
              "Luckgram is an unofficial Telegram client, and many of the services you use in Luckgram are actually provided by Telegram.\n\nPlease read our Privacy Policy before using the app.\n\nBy tapping Continue, you confirm that you have read and agree to the Luckgram Privacy Policy.")
        }
        public var privacyUpdatedTitle: String { t("隐私政策已更新", "Privacy Policy Updated") }
        public var privacyUpdatedText: String {
            t("我们更新了 Luckgram 隐私政策，请花一点时间阅读新版本。\n\n点击「继续」即表示你已阅读并同意更新后的 Luckgram 隐私政策。",
              "We've updated the Luckgram Privacy Policy. Please take a moment to read the new version.\n\nBy tapping Continue, you confirm that you have read and agree to the updated Luckgram Privacy Policy.")
        }
        public var privacyPolicyButton: String { t("隐私政策", "Privacy Policy") }
        public var continueButton: String { t("继续", "Continue") }

        // MARK: Steps

        public func title(_ s: Step) -> String {
            switch s {
            case .ai: return t("AI 让聊天更轻松", "Chat Smarter with AI")
            case .agents: return t("AI 智能体", "AI Agents")
            case .summary: return t("AI 聊天总结", "AI Chat Summary")
            case .discover: return t("附近的人和广场", "Nearby & Square")
            case .pro: return "Luckgram Pro"
            }
        }

        public func body(_ s: Step) -> String {
            switch s {
            case .ai:
                return t("Luckgram 把 AI 放进了输入框：发送前一键翻译成对方的语言，常用回复存成模板一点就发，还能让 AI 帮你回复、润色和改写。",
                         "Luckgram puts AI right in the message field: translate into the other person's language before sending, insert saved replies with a tap, and let AI draft, polish or rewrite your messages.")
            case .agents:
                return t("写作、翻译、出行、学习……每个智能体专注一件事，在 AI 助手里随时找它们帮忙。",
                         "Writing, translating, travel, studying: each agent is focused on one job and ready in the AI assistant whenever you need it.")
            case .summary:
                return t("群里消息太多看不完？让 AI 把最近的聊天整理成要点，还能接着追问细节。",
                         "Too many messages to catch up on? AI turns the recent chat into key points, and you can ask follow-up questions.")
            case .discover:
                return t("找到附近同样开启的 Luckgram 用户，在广场上发图文短帖、点赞和评论。随时可以在「Luckgram 功能」里关闭。",
                         "Find Luckgram users nearby who turned it on, and post, like and comment in the Square. You can turn both off anytime in Luckgram Features.")
            case .pro:
                return t("更多的 AI 额度，让每个 AI 功能都用得尽兴。", "More AI every day, for every AI feature.")
            }
        }

        /// Bold question under the text, or nil.
        public func question(_ s: Step) -> String? {
            switch s {
            case .ai: return t("要开启这些 AI 功能吗？", "Turn on these AI features?")
            case .agents: return t("要开启 AI 智能体吗？", "Turn on AI Agents?")
            default: return nil
            }
        }

        public func primary(_ s: Step) -> String {
            switch s {
            case .ai: return t("开启 AI 功能", "Turn On AI Features")
            case .agents: return t("开启 AI 智能体", "Turn On AI Agents")
            case .pro: return t("订阅", "Subscribe")
            default: return t("继续", "Continue")
            }
        }

        public var comingSoon: String { t("即将推出", "Coming soon") }

        /// The Pro button with the cheapest plan, e.g. "订阅 · 250 ⭐ / 30 天".
        public func subscribe(stars: Int, days: Int) -> String {
            if stars <= 0 {
                return primary(.pro)
            }
            if days > 0 {
                return t("订阅 · \(stars) ⭐ / \(days) 天", "Subscribe · \(stars) ⭐ / \(days) days")
            }
            return t("订阅 · \(stars) ⭐", "Subscribe · \(stars) ⭐")
        }

        public func secondary(_ s: Step) -> String? {
            switch s {
            case .ai: return t("暂不开启", "Continue without AI")
            case .agents: return t("暂不开启", "Continue without AI Agents")
            case .pro: return t("暂不订阅", "Continue without Pro")
            default: return nil
            }
        }

        // MARK: Pro step

        public var proFeatures: [(String, String)] {
            return [
                (t("更多 AI 额度", "More AI every day"),
                 t("AI 对话、写作、总结、智能体、生图和语音转文字，每天可用次数更多。", "Higher daily limits for AI chat, writing, summaries, agents, images and transcription.")),
                (t("所有设备共享", "Shared across devices"),
                 t("绑定同一个 Telegram 账号的设备共享 Pro。", "Every device linked to your Telegram account shares Pro.")),
                (t("用 Telegram Stars 付款", "Paid with Telegram Stars"),
                 t("不需要绑卡，已是 Pro 时再买会从到期时间往后延。", "No card needed. Buying again while Pro extends from the current end date."))
            ]
        }

        public var proFootnote: String { t("登录 Telegram 后完成付款。", "You'll complete the payment after logging in to Telegram.") }

        // MARK: Illustration cards (made-up names and messages)

        public var demoChatName: String { t("小雨", "Mia") }
        public var demoChatStatus: String { t("刚刚在线", "last seen just now") }
        public var demoIncoming: String { t("周末一起去爬山吗？", "Hiking this weekend?") }
        public var demoQuickTitle: String { t("快捷回复", "QUICK REPLIES") }
        public var demoQuickReplies: [String] { [t("好啊，几点出发？", "Sure, what time?"), t("这周有点忙", "Busy this week"), t("改天约", "Maybe next time")] }
        public var demoTranslated: String { "¡Claro! ¿A qué hora?" }
        public var demoTranslatedLabel: String { t("发送前翻译", "Translated") }

        public var demoAgentsTitle: String { t("AI 智能体", "AI Agents") }
        public var demoAgents: [(String, String)] {
            return [
                (t("写作助手", "Writer"), t("邮件、文案、帖子，告诉它要点就行", "Emails, posts and captions from a few notes")),
                (t("出行规划", "Trip Planner"), t("按天排好行程、交通和预算", "Day-by-day plans with transport and budget")),
                (t("学习伙伴", "Study Buddy"), t("把难懂的概念讲清楚，还会出题考你", "Explains hard topics and quizzes you"))
            ]
        }

        public var demoSummaryTitle: String { t("AI 聊天总结", "AI Chat Summary") }
        public var demoSummaryHead: String { t("✦ 总结好了，要点如下：", "✦ Here are the key points:") }
        public var demoSummaryPoints: [String] {
            [t("新版本定在周五上线", "New version ships on Friday"), t("设计稿周三前定稿", "Designs final by Wednesday"),
             t("小林负责安排测试", "Leo sets up the testing"), t("下周一开复盘会", "Review meeting next Monday")]
        }

        public var demoNearby: [(String, String)] { [(t("阿杰", "Jake"), t("300 米", "300 m")), ("Luna", t("1.2 公里", "1.2 km"))] }
        public var demoSquarePost: String { t("今天的晚霞太好看了 🌇", "Tonight's sunset 🌇") }
        public var demoSquareTitle: String { t("广场", "Square") }
        public var demoNearbyTitle: String { t("附近的人", "People Nearby") }
    }
}
