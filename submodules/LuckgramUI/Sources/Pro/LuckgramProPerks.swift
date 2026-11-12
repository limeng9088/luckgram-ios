import Foundation

/// specs#87 (29): what the Pro pages show and which actions are Pro-only, without UI types: the 7
/// perk rows of the subscription page (fixed order, hidden when missing from `pro.perks`), the AI
/// credits line, the summary ranges that need Pro, the reasons in the shared "upgrade" sheet and the
/// "why not Pro" survey after "Continue without Pro". Same wording as Android `ProPerks`.
///
/// Pure (Foundation only, no other Luckgram file) so it is unit tested on its own.
public enum LuckgramProPerks {
    // pro.perks values (S12), same strings as LuckgramProState.perk*
    public static let order: [String] = ["agent_market", "accounts", "ai", "summary", "translate", "community", "no_ads"]

    public static let defaultMonthlyCredits = 50
    public static let defaultSummaryMaxPro = 1000
    /// Free users summarize at most this many messages (S12: free 100).
    public static let summaryFreeMax = 100

    // remote config keys (S4/S12); a missing number is left out of the text
    public static let cfgPerks = "pro.perks"
    public static let cfgMonthlyCredits = "pro.monthly_credits"
    public static let cfgSummaryMax = "pro.summary_max_messages"
    public static let cfgAccountsMaxFree = "accounts.max_free"
    public static let cfgChatPro = "quota.pro.chat_per_day"
    public static let cfgChatFree = "quota.free.chat_per_day"
    public static let cfgTranslatePro = "quota.pro.translate_per_day"
    public static let cfgTranslateFree = "quota.free.translate_per_day"

    /// `model_tier` of /v1/ai/chat for the premium model (S12 需求 3).
    public static let modelTierPremium = "premium"
    public static let errorNotPro = "not_pro"
    public static let errorCreditsExhausted = "credits_exhausted"
    public static let errorQuotaExceeded = "quota_exceeded"

    // "why not Pro" survey (需求 7)
    public static let surveyShownKey = "pro_skip_survey_shown"
    public static let surveyPath = "/v1/feedback/pro-skip"
    public static let surveySource = "onboarding"
    public static let surveyReasons: [String] = ["too_expensive", "prefer_free", "try_first"]

    /// Why the upgrade sheet opens (需求 6).
    public enum Reason {
        case quota
        case proOnly
        case summaryRange
        case followUp
        case premiumModel
    }

    /// Numbers for the perk texts; 0 = unknown (left out of the text).
    public struct Numbers: Equatable {
        public var accountsMaxFree = 0
        public var chatPro = 0
        public var chatFree = 0
        public var monthlyCredits = LuckgramProPerks.defaultMonthlyCredits
        public var summaryMaxPro = LuckgramProPerks.defaultSummaryMaxPro
        public var translatePro = 0
        public var translateFree = 0

        public init() {
        }
    }

    public struct Row: Equatable {
        public let perk: String
        public let proOnly: Bool
        public let title: String
        public let subtitle: String
    }

    /// The live perks: from /v1/me when it sent any, else `pro.perks` of the remote config (comma
    /// separated), else none (the page then keeps its generic text).
    public static func livePerks(fromMe: [String], fromConfig: String?) -> [String] {
        var out: [String] = []
        if !fromMe.isEmpty {
            for p in fromMe {
                let p = p.trimmingCharacters(in: .whitespaces)
                if !p.isEmpty && !out.contains(p) {
                    out.append(p)
                }
            }
            return out
        }
        if let fromConfig {
            let cleaned = fromConfig.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\"", with: "")
            for p in cleaned.split(separator: ",") {
                let p = p.trimmingCharacters(in: .whitespaces)
                if !p.isEmpty && !out.contains(p) {
                    out.append(p)
                }
            }
        }
        return out
    }

    /// `order` filtered by `perks`; unknown names are ignored.
    public static func rows(perks: [String], numbers: Numbers, zh: Bool) -> [Row] {
        let t = Texts(zh: zh)
        return order.filter { perks.contains($0) }.map { p in
            Row(perk: p, proOnly: isProOnlyRow(p), title: t.perkTitle(p), subtitle: t.perkSubtitle(p, numbers))
        }
    }

    /// Rows marked "Pro 专享".
    public static func isProOnlyRow(_ perk: String) -> Bool {
        return perk == "agent_market" || perk == "accounts"
    }

    // MARK: - summary (需求 5)

    public static func summaryNeedsPro(count: Int, pro: Bool) -> Bool {
        return !pro && count > summaryFreeMax
    }

    public static func summaryUnreadCap(unread: Int, pro: Bool, proMax: Int) -> Int {
        let cap = pro ? max(summaryFreeMax, proMax) : summaryFreeMax
        return max(0, min(unread, cap))
    }

    // MARK: - survey (需求 7)

    public static func shouldShowSurvey(fromOnboarding: Bool, alreadyShown: Bool) -> Bool {
        return fromOnboarding && !alreadyShown
    }

    /// The reason code for the chosen option, nil when nothing is chosen (then nothing is sent).
    public static func surveyReason(_ choice: Int?) -> String? {
        guard let choice, choice >= 0, choice < surveyReasons.count else {
            return nil
        }
        return surveyReasons[choice]
    }

    // MARK: - texts

    public struct Texts {
        let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        private func t(_ zh: String, _ en: String) -> String {
            return self.zh ? zh : en
        }

        public var proOnlyBadge: String { t("Pro 专享", "Pro only") }

        public func perkTitle(_ perk: String) -> String {
            switch perk {
            case "agent_market": return t("AI 智能体市场", "AI Agent Market")
            case "accounts": return t("更多账号与云备份", "More Accounts & Cloud Backup")
            case "ai": return t("AI 畅用", "More AI")
            case "summary": return t("AI 聊天分析", "AI Chat Analysis")
            case "translate": return t("内置翻译", "Built-in Translation")
            case "community": return t("Pro 社群", "Pro Community")
            case "no_ads": return t("去除赞助消息", "No Sponsored Messages")
            default: return perk
            }
        }

        public func perkSubtitle(_ perk: String, _ n: Numbers) -> String {
            switch perk {
            case "agent_market":
                return t("发现并使用更多 AI 智能体。", "Discover and use more AI agents.")
            case "accounts":
                // 135: Pro has no account limit (free: accounts.max_free, default 5)
                return n.accountsMaxFree > 0
                    ? t("同时登录的账号数量不限（免费 \(n.accountsMaxFree) 个）；账号备份加密存到云端。", "Log in to unlimited accounts at once (free: \(n.accountsMaxFree)); account backups are encrypted in the cloud.")
                    : t("同时登录的账号数量不限；账号备份加密存到云端。", "Log in to unlimited accounts at once; account backups are encrypted in the cloud.")
            case "ai":
                let daily = n.chatPro > 0
                    ? t("AI 对话每天 \(n.chatPro) 次" + (n.chatFree > 0 ? "（免费 \(n.chatFree) 次）" : ""), "AI chat \(n.chatPro) times a day" + (n.chatFree > 0 ? " (free: \(n.chatFree))" : ""))
                    : t("AI 对话每天可用次数更多", "More AI chats every day")
                return daily + t("，每月另送 \(n.monthlyCredits) 个 AI 点数，用于高级模型。", ", plus \(n.monthlyCredits) AI credits a month for the premium model.")
            case "summary":
                return t("总结最多 \(n.summaryMaxPro) 条消息并可追问（免费 \(LuckgramProPerks.summaryFreeMax) 条）。", "Summarize up to \(n.summaryMaxPro) messages and ask follow-up questions (free: \(LuckgramProPerks.summaryFreeMax)).")
            case "translate":
                return n.translatePro > 0
                    ? t("每天翻译 \(n.translatePro) 次" + (n.translateFree > 0 ? "（免费 \(n.translateFree) 次）" : "") + "。", "Translate \(n.translatePro) times a day" + (n.translateFree > 0 ? " (free: \(n.translateFree))" : "") + ".")
                    : t("每天可翻译的次数更多。", "More translations every day.")
            case "community":
                return t("加入 Luckgram Pro 用户私密群。", "Join the private group for Luckgram Pro users.")
            case "no_ads":
                return t("频道里不显示 Telegram 赞助消息。", "Telegram sponsored messages are hidden in channels.")
            default:
                return ""
            }
        }

        public var creditsTitle: String { t("本月 AI 点数", "AI credits this month") }

        /// "剩余 N / 50，X 日重置"; without a reset time just "剩余 N / 50".
        public func creditsValue(remaining: Int, total: Int, resetsAt: Date?, timeZone: TimeZone = .current) -> String {
            let left = t("剩余 \(max(0, remaining)) / \(total)", "\(max(0, remaining)) / \(total) left")
            guard let resetsAt else {
                return left
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let day = calendar.component(.day, from: resetsAt)
            let month = calendar.component(.month, from: resetsAt)
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            return left + t("，\(day) 日重置", ", resets \(months[(month - 1 + 12) % 12]) \(day)")
        }

        public func creditsLine(remaining: Int, total: Int, resetsAt: Date?, timeZone: TimeZone = .current) -> String {
            return creditsTitle + t(" ", ": ") + creditsValue(remaining: remaining, total: total, resetsAt: resetsAt, timeZone: timeZone)
        }

        // model choice (需求 3)
        public var modelTitle: String { t("模型", "Model") }
        public var modelStandard: String { t("标准模型", "Standard model") }
        public var modelPremium: String { t("高级模型 · 每条 1 点", "Premium model · 1 credit per message") }
        public var creditsExhausted: String { t("本月 AI 点数已用完，已切回标准模型。", "You've used all AI credits for this month. Switched back to the standard model.") }

        // upgrade sheet (需求 6)
        public var upgradeTitle: String { t("升级 Luckgram Pro", "Upgrade to Luckgram Pro") }
        public var upgradeButton: String { t("查看 Pro", "See Pro") }

        public func upgradeReason(_ r: Reason) -> String {
            switch r {
            case .quota:
                return t("今天的 AI 额度已用完。开通 Pro 每天可以用更多次。", "You've used up today's AI quota. Pro gives you more every day.")
            case .summaryRange:
                return t("总结 \(LuckgramProPerks.summaryFreeMax) 条以上的消息是 Pro 专享。", "Summarizing more than \(LuckgramProPerks.summaryFreeMax) messages is for Pro members.")
            case .followUp:
                return t("对总结结果追问是 Pro 专享。", "Asking follow-up questions about a summary is for Pro members.")
            case .premiumModel:
                return t("高级模型是 Pro 专享，每月送 AI 点数。", "The premium model is for Pro members, with AI credits every month.")
            case .proOnly:
                return t("这是 Pro 专享功能。", "This feature is for Pro members.")
            }
        }

        // summary (需求 5)
        public func allUnread(_ n: Int) -> String { t("全部未读（\(n) 条）", "All unread (\(n))") }
        public var followUpHintFree: String { t("追问（Pro 专享）", "Ask follow-ups (Pro only)") }

        // survey (需求 7)
        public var surveySubtitle: String { t("想听听你的想法", "We'd love your thoughts") }
        public var surveyTitle: String { t("为什么暂不开通 Pro？", "Why not Pro for now?") }
        public var surveyTitleAccent: String { "Pro" }
        public var surveyOptions: [String] { [t("价格太贵", "It's too expensive"), t("我更想免费使用", "I'd rather use it for free"), t("想先试用再决定", "I'd like to try it first")] }
        public var surveyContinue: String { t("继续", "Continue") }
        public var surveySkip: String { t("跳过", "Skip") }
    }
}
