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
    /// with the chosen code. specs#105: `recent` goes on top.
    public var pickLanguage: ((_ selected: String?, _ recent: [String], _ completion: @escaping (String) -> Void) -> Void)?

    // MARK: - specs#105: default + per chat

    private static let recentKey = "translate_in_recent"
    private static func chatKey(_ peerId: EnginePeer.Id) -> String {
        return "translate_in_to_lang_\(peerId.toInt64())"
    }

    /// This chat's own 「翻译成」 (per account), or nil when it follows the default.
    public static func chatLanguage(accountPeerId: EnginePeer.Id, peerId: EnginePeer.Id) -> String? {
        return LuckgramTranslateInLogic.targetLanguage(chosen: LuckgramSettings.shared.string(chatKey(peerId), forAccount: accountPeerId.toInt64(), default: nil))
    }

    /// `code` nil = follow the default again.
    public static func setChatLanguage(accountPeerId: EnginePeer.Id, peerId: EnginePeer.Id, _ code: String?) {
        LuckgramSettings.shared.setString(chatKey(peerId), code ?? "", forAccount: accountPeerId.toInt64())
    }

    /// The language messages of this chat are translated into: its own choice ?? the default ?? nil.
    public static func targetLanguage(accountPeerId: EnginePeer.Id, peerId: EnginePeer.Id) -> String? {
        return LuckgramTranslateInLogic.effectiveLanguage(chatChosen: chatLanguage(accountPeerId: accountPeerId, peerId: peerId), defaultChosen: LuckgramSettings.shared.string(toLangKey, default: nil))
    }

    /// The default for every chat without its own choice (settings 「翻译成」).
    public static func setDefaultLanguage(_ code: String) {
        LuckgramSettings.shared.setString(toLangKey, code)
    }

    public static func recentLanguages(accountPeerId: EnginePeer.Id) -> [String] {
        let stored = LuckgramSettings.shared.string(recentKey, forAccount: accountPeerId.toInt64(), default: nil) ?? ""
        return stored.split(separator: ",").map(String.init)
    }

    private static func addRecent(accountPeerId: EnginePeer.Id, code: String) {
        let stored = LuckgramSettings.shared.string(recentKey, forAccount: accountPeerId.toInt64(), default: nil)
        LuckgramSettings.shared.setString(recentKey, LuckgramTranslateInLogic.updatingRecent(stored, code: code), forAccount: accountPeerId.toInt64())
    }

    /// specs#105 §2: asks whether `languageName` is for this chat only (`true`) or the new default (`false`).
    /// Only asks; the caller saves, so other features (e.g. image translation) can reuse it.
    public static func askScope(context: AccountContext, languageName: String, completion: @escaping (_ chatOnly: Bool) -> Void) {
        let zh = LuckgramStrings.isChinese
        let alert = UIAlertController(
            title: zh ? "翻译成\(languageName)" : "Translate into \(languageName)",
            message: zh ? "只在这个聊天里使用，还是设为所有聊天的默认语言？" : "Use it only in this chat, or make it the default for all chats?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: zh ? "仅本聊天" : "This chat only", style: .default, handler: { _ in completion(true) }))
        alert.addAction(UIAlertAction(title: zh ? "设为默认" : "Set as default", style: .default, handler: { _ in completion(false) }))
        alert.addAction(UIAlertAction(title: zh ? "取消" : "Cancel", style: .cancel, handler: nil))
        context.sharedContext.mainWindow?.presentNative(alert)
    }

    public static func languageName(_ code: String?) -> String? {
        guard let code = LuckgramTranslateInLogic.base(code) else {
            return nil
        }
        let locale = Locale(identifier: LuckgramStrings.isChinese ? "zh-Hans" : "en")
        return locale.localizedString(forLanguageCode: code) ?? code
    }

    /// specs#105: the language list for a chat (current first, recently used next). The first choice ever
    /// becomes the default; later changes ask 「仅本聊天 / 设为默认」. `then` runs once it is saved.
    public func chooseLanguage(accountPeerId: EnginePeer.Id, peerId: EnginePeer.Id, then: @escaping (String) -> Void) {
        guard let pickLanguage = self.pickLanguage else {
            return
        }
        let current = LuckgramTranslateInController.targetLanguage(accountPeerId: accountPeerId, peerId: peerId)
        pickLanguage(LuckgramTranslateInLogic.base(current), LuckgramTranslateInController.recentLanguages(accountPeerId: accountPeerId), { [weak self] code in
            LuckgramTranslateInController.addRecent(accountPeerId: accountPeerId, code: code)
            if LuckgramTranslateInController.targetLanguage == nil {
                LuckgramTranslateInController.setDefaultLanguage(code)
                LuckgramTranslateInController.setChatLanguage(accountPeerId: accountPeerId, peerId: peerId, nil)
                then(code)
                return
            }
            if code == current && LuckgramTranslateInController.chatLanguage(accountPeerId: accountPeerId, peerId: peerId) != nil {
                then(code)
                return
            }
            guard let context = self?.context() else {
                return
            }
            LuckgramTranslateInController.askScope(context: context, languageName: LuckgramTranslateInController.languageName(code) ?? code, completion: { chatOnly in
                if chatOnly {
                    LuckgramTranslateInController.setChatLanguage(accountPeerId: accountPeerId, peerId: peerId, code)
                } else {
                    LuckgramTranslateInController.setDefaultLanguage(code)
                    LuckgramTranslateInController.setChatLanguage(accountPeerId: accountPeerId, peerId: peerId, nil)
                }
                then(code)
            })
        })
    }

    public func changeLanguage(accountPeerId: EnginePeer.Id, messageId: EngineMessage.Id, text: String, voice: Bool, updated: @escaping () -> Void) {
        self.chooseLanguage(accountPeerId: accountPeerId, peerId: messageId.peerId) { [weak self] _ in
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

    public func showButton(text: String, accountPeerId: EnginePeer.Id, peerId: EnginePeer.Id) -> Bool {
        if !self.isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return LuckgramTranslateInLogic.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: self.language(of: text), doNotTranslate: self.excluded, toLang: LuckgramTranslateInController.targetLanguage(accountPeerId: accountPeerId, peerId: peerId))
    }

    public func showVoiceLink(text: String, accountPeerId: EnginePeer.Id, peerId: EnginePeer.Id) -> Bool {
        return self.showButton(text: text, accountPeerId: accountPeerId, peerId: peerId)
    }

    public func languageButton(toLang: String?) -> String {
        return LuckgramTranslateInLogic.languageButton(toName: LuckgramTranslateInController.languageName(toLang ?? LuckgramTranslateInController.targetLanguage) ?? "")
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
        guard let toLang = LuckgramTranslateInController.targetLanguage(accountPeerId: accountPeerId, peerId: messageId.peerId) else {
            // specs#93: the first translation asks for the language, then translates this message
            self.chooseLanguage(accountPeerId: accountPeerId, peerId: messageId.peerId) { [weak self] _ in
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
