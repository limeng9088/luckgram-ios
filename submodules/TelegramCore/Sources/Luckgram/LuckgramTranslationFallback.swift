import Foundation
import SwiftSignalKit

/// Luckgram specs#82: Luckgram AI as the fallback translator when Telegram's translation fails.
/// TelegramCore (and TranslateUI / TextProcessingScreen, which LuckgramUI depends on) cannot import
/// LuckgramUI, so the app installs the implementation (`LuckgramTranslateService`) at startup.
public protocol LuckgramTranslationFallbackService: AnyObject {
    /// Translates `text` into `toLang` with Luckgram AI. Fails with the Luckgram API error code
    /// (`network_error`, `quota_exceeded`, `input_too_large`, `consent_denied`, …).
    func translate(source: String, text: String, toLang: String) -> Signal<String, LuckgramTranslationFallbackError>
    /// Writes Telegram's failure (error code / text, `TIMEOUT`, `EMPTY_RESULT`) to the specs#72 diagnostic log.
    func logTelegramFailure(source: String, code: Int, text: String)
    /// Tells the user why the translation failed (both Telegram and Luckgram AI).
    func showFailure(_ error: LuckgramTranslationFallbackError)
    /// The user-facing message for `error`.
    func failureMessage(_ error: LuckgramTranslationFallbackError) -> String
}

public struct LuckgramTranslationFallbackError: Error, Equatable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// Installed by the app; nil in extensions and tests (then the Telegram error stands as before).
public var luckgramTranslationFallback: LuckgramTranslationFallbackService?
