import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext
import UndoUI

/// Luckgram specs#82: Luckgram AI as the fallback translator when Telegram's translation fails
/// (translate-before-sending, long-press "Translate", "Translate entire chat"). Installed into
/// TelegramCore's `luckgramTranslationFallback` by `SharedAccountContext`, because TelegramCore,
/// TranslateUI and TextProcessingScreen cannot import LuckgramUI.
public final class LuckgramTranslateService: LuckgramTranslationFallbackService {
    private let context: () -> AccountContext?
    private let present: (ViewController) -> Void

    /// - Parameters:
    ///   - context: the current account, for the one-time AI consent dialog.
    ///   - present: shows the consent dialog and failure toasts on top of the app.
    public init(context: @escaping () -> AccountContext?, present: @escaping (ViewController) -> Void) {
        self.context = context
        self.present = present
    }

    public static func install(context: @escaping () -> AccountContext?, present: @escaping (ViewController) -> Void) {
        luckgramTranslationFallback = LuckgramTranslateService(context: context, present: present)
    }

    public func translate(source: String, text: String, toLang: String) -> Signal<String, LuckgramTranslationFallbackError> {
        guard let lang = LuckgramTranslateFallbackLogic.aiLanguage(toLang), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail(LuckgramTranslationFallbackError(code: LuckgramAIError.invalidRequest))
        }
        let present = self.present
        // The consent dialog (first AI use only) must be presented on the main queue.
        return (Signal<AccountContext?, NoError> { [weak self] subscriber in
            subscriber.putNext(self?.context())
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(Queue.mainQueue())
        |> castError(LuckgramAIError.self)
        |> mapToSignal { context -> Signal<String, LuckgramAIError> in
            return LuckgramAI.shared.translate(context: context, present: present, text: text, toLang: lang)
        })
        |> mapError { error -> LuckgramTranslationFallbackError in
            return LuckgramTranslationFallbackError(code: error.code)
        }
    }

    public func logTelegramFailure(source: String, code: Int, text: String) {
        let method = source == LuckgramTranslateFallbackLogic.sourceMessage ? "messages.composeMessageWithAI" : "messages.translateText"
        LuckgramNet.shared.logTelegram(feature: source, method: method, code: code, text: text)
    }

    public func failureMessage(_ error: LuckgramTranslationFallbackError) -> String {
        return LuckgramTranslateFallbackLogic.failureMessage(LuckgramTranslateFallbackLogic.failure(code: error.code), chinese: LuckgramStrings.isChinese)
    }

    public func showFailure(_ error: LuckgramTranslationFallbackError) {
        if error.code == LuckgramAIError.cancelled {
            return
        }
        let text = self.failureMessage(error)
        Queue.mainQueue().async { [weak self] in
            guard let self, let context = self.context() else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            self.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
        }
    }
}
