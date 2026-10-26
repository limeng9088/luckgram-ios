import Foundation

/// Luckgram UI strings in Chinese and English. Telegram has no bundled Chinese localization, so
/// Luckgram strings pick Chinese when the system language or the Telegram language is Chinese.
public enum LuckgramStrings {
    /// Language code of the Telegram UI language; updated by Luckgram screens from PresentationData.
    public static var appLanguageCode: String?

    public static var isChinese: Bool {
        if let code = appLanguageCode?.lowercased(), code.hasPrefix("zh") {
            return true
        }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    }

    public static func pick(_ zh: String, _ en: String) -> String {
        return isChinese ? zh : en
    }

    public static var featuresTitle: String { pick("Luckgram 功能", "Luckgram Features") }

    public static func footer(version: String) -> String {
        return pick("Luckgram \(version)\nLuckgram 是基于 Telegram 开源代码的独立应用", "Luckgram \(version)\nLuckgram is an independent app based on Telegram's open-source code")
    }

    public static var comingSoon: String { pick("即将推出", "Coming soon") }

    // MARK: AI

    public static var aiConsentTitle: String { pick("使用 AI 服务", "Use AI service") }
    public static var aiConsentText: String { pick("你选中的内容会发送到 Luckgram 的 AI 服务，由 OpenAI 处理后返回。", "The content you select will be sent to Luckgram's AI service and processed by OpenAI.") }
    public static var aiConsentAgree: String { pick("同意", "Agree") }
    public static var aiConsentDecline: String { pick("不同意", "Decline") }
    public static var aiConsentRow: String { pick("AI 服务授权", "AI service consent") }
    public static var aiConsentAllowed: String { pick("已同意", "Allowed") }
    public static var aiConsentNotAllowed: String { pick("未同意", "Not allowed") }
    public static var aiConsentGrantedFooter: String { pick("已同意，点按可撤回。撤回后下次使用 AI 功能时会重新询问。", "Allowed. Tap to revoke; you'll be asked again the next time you use an AI feature.") }
    public static var aiConsentNotGrantedFooter: String { pick("未同意，首次使用 AI 功能时会询问。", "Not allowed. You'll be asked the first time you use an AI feature.") }
    public static var aiRevokeTitle: String { pick("撤回 AI 授权？", "Revoke AI consent?") }
    public static var aiRevokeText: String { pick("撤回后，下次使用 AI 功能时会重新询问。", "You'll be asked again the next time you use an AI feature.") }
    public static var aiRevoke: String { pick("撤回", "Revoke") }
    public static var cancel: String { pick("取消", "Cancel") }
    public static var ok: String { pick("好", "OK") }

    public static func errorMessage(_ code: String) -> String {
        switch code {
        case LuckgramAIError.quotaExceeded:
            return pick("今天的 AI 额度已用完，请明天再试。", "You've used up today's AI quota. Please try again tomorrow.")
        case LuckgramAIError.contentRejected:
            return pick("内容被 AI 服务拒绝。", "The content was rejected by the AI service.")
        case LuckgramAIError.rateLimited:
            return pick("请求太频繁，请稍后再试。", "Too many requests. Please wait a moment and try again.")
        case LuckgramAIError.networkError:
            return pick("网络错误，请检查网络后重试。", "Network error. Please check your connection and try again.")
        case LuckgramAIError.inputTooLarge:
            return pick("内容太长，无法处理。", "The content is too large to process.")
        case LuckgramAIError.consentDenied:
            return pick("你没有同意使用 AI 服务。", "You didn't allow the AI service.")
        case LuckgramAIError.cancelled:
            return pick("已取消。", "Cancelled.")
        default:
            return pick("AI 服务暂时不可用，请稍后再试。", "The AI service is temporarily unavailable. Please try again later.")
        }
    }

    public static func group(_ group: LuckgramFeature.Group) -> String {
        switch group {
        case .accountPrivacy:
            return pick("账号与隐私", "Accounts & Privacy")
        case .messagesLanguage:
            return pick("消息与语言", "Messages & Language")
        case .mediaCallsStorage:
            return pick("媒体、通话与存储", "Media, Calls & Storage")
        case .profileOrganize:
            return pick("资料与整理", "Profiles & Organization")
        case .ai:
            return "AI"
        case .debug:
            return pick("调试", "Debug")
        }
    }
}
