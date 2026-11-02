import Foundation

/// Luckgram specs#82: when Telegram's `messages.translateText` fails, the text is translated by the
/// Luckgram API (`/v1/ai/chat` task=translate) instead of Google's web translator, which is
/// unreachable for many users. Foundation only, unit tested on Linux; same rules as Android
/// `org.telegram.luckgram.translateout.TranslateFallbackLogic`.
public enum LuckgramTranslateFallbackLogic {
    /// Diagnostic-log feature names, one per entry point (specs#82 §1).
    public static let sourceOut = "translate_out"
    public static let sourceMessage = "translate_message"
    public static let sourceChat = "translate_chat"

    /// Telegram gets this long before we stop waiting and fall back.
    public static let telegramTimeoutSeconds: Double = 15.0

    /// Logged instead of a Telegram error text when no error came.
    public static let timeout = "TIMEOUT"
    public static let emptyResult = "EMPTY_RESULT"

    /// Why the fallback failed too, for the message shown to the user (specs#82 §3).
    public enum Failure: Equatable {
        case other
        case network
        case quota
        case tooLong
        case consent
    }

    /// Whether Luckgram AI should translate instead: on every Telegram failure (any error, a timeout
    /// or an empty result), never when Telegram gave a usable result, so no AI quota is spent while
    /// Telegram works.
    public static func shouldFallback(telegramGaveText: Bool) -> Bool {
        return !telegramGaveText
    }

    /// What the diagnostic log records for Telegram's failure.
    public static func telegramFailure(errorText: String?, timedOut: Bool) -> String {
        if timedOut {
            return timeout
        }
        let trimmed = (errorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? emptyResult : trimmed
    }

    /// The `to_lang` sent to the server: an ISO 639-1 (or 639-2) code, with the script / region only
    /// where it changes the written language (zh-Hant, pt-BR). Accepts forms such as `zh_TW`,
    /// `zh-hans`, `nb`, `pt_br`. Nil when unusable.
    public static func aiLanguage(_ code: String?) -> String? {
        guard let code else {
            return nil
        }
        let s = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if s.isEmpty || s == "und" {
            return nil
        }
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(parts[0])
        let rest = parts.count > 1 ? String(parts[1]) : ""
        guard (2 ... 3).contains(base.count), base.unicodeScalars.allSatisfy({ $0 >= "a" && $0 <= "z" }) else {
            return nil
        }
        switch base {
        case "zh":
            return (rest == "hant" || rest.hasPrefix("hant-") || rest == "tw" || rest == "hk" || rest == "mo") ? "zh-Hant" : "zh"
        case "pt":
            return rest == "br" ? "pt-BR" : "pt"
        case "nb", "nn":
            return "no"
        case "iw":
            return "he"
        case "in":
            return "id"
        default:
            return base
        }
    }

    /// Maps the Luckgram API error code of the failed fallback to a `Failure`.
    public static func failure(code: String?) -> Failure {
        switch code {
        case "network_error":
            return .network
        case "quota_exceeded":
            return .quota
        case "input_too_large":
            return .tooLong
        case "consent_denied":
            return .consent
        default:
            return .other
        }
    }

    /// The message shown when both Telegram and Luckgram AI failed.
    public static func failureMessage(_ failure: Failure, chinese: Bool) -> String {
        switch failure {
        case .network:
            return chinese ? "翻译失败：网络不通，请检查网络后重试。" : "Translation failed: no network connection. Please check your network and try again."
        case .quota:
            return chinese ? "翻译失败：今天的 AI 额度已用完，请明天再试。" : "Translation failed: today's AI quota is used up. Please try again tomorrow."
        case .tooLong:
            return chinese ? "翻译失败：文字太长，请分段翻译。" : "Translation failed: the text is too long. Please translate it in parts."
        case .consent:
            return chinese ? "翻译失败：Telegram 翻译不可用，需要同意使用 AI 服务才能改用 Luckgram 翻译。" : "Translation failed: Telegram translation is unavailable, and Luckgram translation needs your consent to use the AI service."
        case .other:
            return chinese ? "翻译失败，请稍后再试。" : "Translation failed. Please try again later."
        }
    }
}
