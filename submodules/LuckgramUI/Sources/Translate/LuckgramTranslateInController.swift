import Foundation
import UIKit
import NaturalLanguage
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext

/// Luckgram spec 01 A/B: translates a received message (or a voice transcription) and shows the
/// translation in its bubble, below the original. Translation: cache → Telegram
/// `messages.translateText` (8 s) → Luckgram AI. Installed into TelegramCore's
/// `luckgramTranslateIn` by `SharedAccountContext`.
public final class LuckgramTranslateInController: LuckgramTranslateInService {
    /// LuckgramSettings key of 「翻译成」; empty = not chosen yet (asked on the first translation, specs#93).
    public static let toLangKey = "translate_in_to_lang"

    private let context: () -> AccountContext?
    /// 「不翻译的语言」: Telegram's "Do not translate" list (set by the app), default the app language.
    public var doNotTranslate: [String]?
    private var detected: [String: String] = [:]
    private var pending = Set<String>()

    public init(context: @escaping () -> AccountContext?) {
        self.context = context
    }

    @discardableResult
    public static func install(context: @escaping () -> AccountContext?) -> LuckgramTranslateInController {
        let controller = LuckgramTranslateInController(context: context)
        luckgramTranslateIn = controller
        return controller
    }

    public var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramTranslateInLogic.featureKey)
    }

    /// 「翻译成」 as the user chose it, or nil before the first choice (specs#93).
    public static var targetLanguage: String? {
        return LuckgramTranslateInLogic.targetLanguage(chosen: LuckgramSettings.shared.string(toLangKey, default: nil))
    }

    /// specs#93: shows the language list (set by TelegramUI: it lives in ChatTextInputPanelNode); calls back
    /// with the chosen code.
    public var pickLanguage: ((_ selected: String?, _ completion: @escaping (String) -> Void) -> Void)?

    private func askLanguage(_ then: @escaping (String) -> Void) {
        guard let pickLanguage = self.pickLanguage else {
            return
        }
        pickLanguage(LuckgramTranslateInLogic.base(LuckgramTranslateInController.targetLanguage), { code in
            LuckgramSettings.shared.setString(LuckgramTranslateInController.toLangKey, code)
            then(code)
        })
    }

    public func changeLanguage(accountPeerId: EnginePeer.Id, messageId: EngineMessage.Id, text: String, voice: Bool, updated: @escaping () -> Void) {
        self.askLanguage { [weak self] _ in
            LuckgramMessageTranslations.shared.remove(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice)
            updated()
            self?.toggle(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice, updated: updated)
        }
    }

    private var excluded: [String] {
        if let list = self.doNotTranslate, !list.isEmpty {
            return list
        }
        return [LuckgramStrings.appLanguageCode ?? Locale.preferredLanguages.first ?? "en"]
    }

    /// On-device language detection (NaturalLanguage), cached per text.
    private func language(of text: String) -> String? {
        let key = LuckgramTranslateCache.key(toLang: "", text: text)
        if let value = self.detected[key] {
            return value.isEmpty ? nil : value
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        let value = recognizer.dominantLanguage?.rawValue ?? ""
        if self.detected.count > 2000 {
            self.detected.removeAll()
        }
        self.detected[key] = value
        return value.isEmpty ? nil : value
    }

    public func showButton(text: String) -> Bool {
        if !self.isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return LuckgramTranslateInLogic.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: self.language(of: text), doNotTranslate: self.excluded, toLang: LuckgramTranslateInController.targetLanguage)
    }

    public func showVoiceLink(text: String) -> Bool {
        return self.showButton(text: text)
    }

    public func header(fromLang: String?, toLang: String?) -> String {
        let chinese = LuckgramStrings.isChinese
        func name(_ code: String?) -> String? {
            guard let code = LuckgramTranslateInLogic.base(code) else {
                return nil
            }
            let locale = Locale(identifier: chinese ? "zh-Hans" : "en")
            return locale.localizedString(forLanguageCode: code) ?? code
        }
        return LuckgramTranslateInLogic.header(fromName: name(fromLang), toName: name(toLang ?? LuckgramTranslateInController.targetLanguage) ?? "", chinese: chinese)
    }

    public func toggle(accountPeerId: EnginePeer.Id, messageId: EngineMessage.Id, text: String, voice: Bool, updated: @escaping () -> Void) {
        let store = LuckgramMessageTranslations.shared
        if store.entry(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice) != nil {
            store.remove(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice)
            updated()
            return
        }
        guard let toLang = LuckgramTranslateInController.targetLanguage else {
            // specs#93: the first translation asks for the language, then translates this message
            self.askLanguage { [weak self] _ in
                self?.toggle(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice, updated: updated)
            }
            return
        }
        let pendingKey = "\(voice):\(accountPeerId.toInt64()):\(messageId.peerId.toInt64()):\(messageId.id)"
        if self.pending.contains(pendingKey) {
            return
        }
        self.pending.insert(pendingKey)
        let detectedFrom = self.language(of: text)
        let source = voice ? "translate_voice" : LuckgramTranslateFallbackLogic.sourceMessage
        let _ = (self.translate(source: source, text: text, toLang: toLang)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] translated, fromLang in
            self?.pending.remove(pendingKey)
            store.set(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice, translated: translated, fromLang: fromLang ?? detectedFrom, toLang: toLang)
            updated()
        }, error: { [weak self] error in
            self?.pending.remove(pendingKey)
            luckgramTranslationFallback?.showFailure(error)
        })
    }

    /// spec 01 「翻译服务」: cache → Telegram (8 s) → Luckgram AI. Emits (translation, source language).
    private func translate(source: String, text: String, toLang: String) -> Signal<(String, String?), LuckgramTranslationFallbackError> {
        if let lang = LuckgramTranslateFallbackLogic.aiLanguage(toLang), let hit = LuckgramTranslateService.cached(toLang: lang, text: text) {
            return .single((hit.text, hit.fromLang))
        }
        guard let context = self.context() else {
            return .fail(LuckgramTranslationFallbackError(code: LuckgramAIError.networkError))
        }
        enum Telegram {
            case ok(String)
            case failed(timedOut: Bool)
        }
        let telegram: Signal<Telegram, NoError> = context.engine.messages.translate(text: text, toLang: toLang)
        |> map { result -> Telegram in
            if let result, !result.0.isEmpty {
                return .ok(result.0)
            }
            return .failed(timedOut: false)
        }
        |> `catch` { _ -> Signal<Telegram, NoError> in
            // The Telegram error itself is logged by TelegramCore.
            return .single(.failed(timedOut: false))
        }
        |> timeout(LuckgramTranslateFallbackLogic.telegramTimeoutSeconds, queue: Queue.mainQueue(), alternate: .single(.failed(timedOut: true)))

        return telegram
        |> castError(LuckgramTranslationFallbackError.self)
        |> mapToSignal { result -> Signal<(String, String?), LuckgramTranslationFallbackError> in
            switch result {
            case let .ok(translated):
                if let lang = LuckgramTranslateFallbackLogic.aiLanguage(toLang) {
                    LuckgramTranslateService.remember(toLang: lang, text: text, translated: translated, fromLang: nil)
                }
                return .single((translated, nil))
            case let .failed(timedOut):
                if timedOut {
                    luckgramTranslationFallback?.logTelegramFailure(source: source, code: 0, text: LuckgramTranslateFallbackLogic.timeout)
                }
                guard let fallback = luckgramTranslationFallback else {
                    return .fail(LuckgramTranslationFallbackError(code: LuckgramAIError.upstreamUnavailable))
                }
                return fallback.translate(source: source, text: text, toLang: toLang)
                |> map { translated -> (String, String?) in
                    let lang = LuckgramTranslateFallbackLogic.aiLanguage(toLang)
                    let from = lang.flatMap { LuckgramTranslateService.cached(toLang: $0, text: text)?.fromLang }
                    return (translated, from)
                }
            }
        }
    }
}
