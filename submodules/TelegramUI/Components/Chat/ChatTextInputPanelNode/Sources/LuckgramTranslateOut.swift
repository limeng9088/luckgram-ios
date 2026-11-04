// Luckgram: translate the message being composed before it is sent (feature 01, "translate_out").
//
// Translation goes through Telegram's own messages.translateText; only when that fails is the text sent to the
// Luckgram API instead (specs#82, `luckgramTranslationFallback`).
// Per-chat target languages live in the account's postbox item cache, so they are removed together
// with the account data on logout.

import Foundation
import UIKit
import NaturalLanguage
import SwiftSignalKit
import TelegramCore
import TextFormat
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import LuckgramUI

public enum LuckgramTranslateOut {
    /// Switch key, registered in `LuckgramFeatures` ("消息与语言" group, default on).
    public static let featureKey = "translate_out"

    /// Fallback when neither the chat nor the peer's last message gives us a language.
    public static let fallbackLanguage = "en"

    /// Most used languages, shown first in the picker.
    public static let commonLanguages = ["en", "es", "fr", "de", "ru", "zh", "ja", "ko", "pt", "ar", "it", "tr", "uk", "vi", "id", "hi"]

    /// Languages accepted by messages.translateText.
    static let allLanguages = [
        "af", "sq", "am", "ar", "hy", "az", "eu", "be", "bn", "bs", "bg", "ca", "ceb", "zh", "co", "hr", "cs", "da", "nl", "en",
        "eo", "et", "fi", "fr", "fy", "gl", "ka", "de", "el", "gu", "ht", "ha", "haw", "he", "hi", "hmn", "hu", "is", "ig", "id",
        "ga", "it", "ja", "jv", "kn", "kk", "km", "rw", "ko", "ku", "ky", "lo", "lv", "lt", "lb", "mk", "mg", "ms", "ml", "mt",
        "mi", "mr", "mn", "my", "ne", "no", "ny", "or", "ps", "fa", "pl", "pt", "pa", "ro", "ru", "sm", "gd", "sr", "st", "sn",
        "sd", "si", "sk", "sl", "so", "es", "su", "sw", "sv", "tl", "tg", "ta", "tt", "te", "th", "tr", "tk", "uk", "ur", "ug",
        "uz", "vi", "cy", "xh", "yi", "yo", "zu"
    ]

    // MARK: - Switch

    /// Local switch on "Settings -> Luckgram features" and not switched off remotely (`LuckgramSettings`,
    /// feature 00). The default (on) comes from the registry.
    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(featureKey)
    }

    // MARK: - specs#104: per chat 「发送翻译」 {on, language}

    private static let chatsOnKey = "translate_out_chats_on"
    private static func chatOnKey(_ peerId: EnginePeer.Id) -> String {
        return "translate_out_on_\(peerId.toInt64())"
    }
    /// LuckgramSettings key; "1" = send the translation without the preview.
    public static let noPreviewKey = "translate_out_no_preview"

    /// The target language while 「发送翻译」 is on for this chat, else nil (per account, synchronous so the
    /// input panel can show the capsule).
    public static func chatLanguageIfOn(accountPeerId: EnginePeer.Id, peerId: EnginePeer.Id) -> String? {
        guard let value = LuckgramSettings.shared.string(chatOnKey(peerId), forAccount: accountPeerId.toInt64(), default: nil), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// On with `code`, or off with nil. Also keeps the per-chat language (01) in sync.
    public static func setChat(context: AccountContext, peerId: EnginePeer.Id, on code: String?) {
        let accountId = context.account.peerId.toInt64()
        LuckgramSettings.shared.setString(chatOnKey(peerId), code ?? "", forAccount: accountId)
        let stored = LuckgramSettings.shared.string(chatsOnKey, forAccount: accountId, default: nil)
        LuckgramSettings.shared.setString(chatsOnKey, LuckgramSendTranslateLogic.updatingChats(stored, peerId: peerId.toInt64(), on: code != nil), forAccount: accountId)
        if let code {
            saveLanguage(context: context, peerId: peerId, code: code)
        }
    }

    /// specs#104 §6: the chats with 「发送翻译」 on (peer id, language).
    public static func chatsOn(context: AccountContext) -> [(peerId: EnginePeer.Id, language: String)] {
        let accountPeerId = context.account.peerId
        let stored = LuckgramSettings.shared.string(chatsOnKey, forAccount: accountPeerId.toInt64(), default: nil)
        return LuckgramSendTranslateLogic.decodeChats(stored).compactMap { raw in
            let peerId = EnginePeer.Id(raw)
            guard let language = chatLanguageIfOn(accountPeerId: accountPeerId, peerId: peerId) else {
                return nil
            }
            return (peerId, language)
        }
    }

    public static var previewEnabled: Bool {
        get {
            return LuckgramSettings.shared.string(noPreviewKey, default: nil) != "1"
        }
        set {
            LuckgramSettings.shared.setString(noPreviewKey, newValue ? "" : "1")
        }
    }

    /// 「发送前翻译…」 (chat menu, TelegramUI).
    public static var chatMenuTitle: String {
        return LuckgramStrings.isChinese ? "发送前翻译…" : "Translate before sending…"
    }

    /// 「中 → EN」 for a chat.
    static func capsule(language: String) -> String {
        let from = LuckgramStrings.appLanguageCode ?? Locale.preferredLanguages.first
        return LuckgramSendTranslateLogic.capsule(from: from, to: language)
    }

    // MARK: - Strings

    /// Same rule as every other Luckgram string (`LuckgramStrings`, feature 00).
    static func isChinese(_ strings: PresentationStrings?) -> Bool {
        return LuckgramStrings.isChinese
    }

    struct Strings {
        let chinese: Bool

        init(_ strings: PresentationStrings?) {
            self.chinese = LuckgramTranslateOut.isChinese(strings)
        }

        var button: String { return self.chinese ? "翻译" : "Translate" }
        var undo: String { return self.chinese ? "撤销" : "Undo" }
        var failed: String { return self.chinese ? "翻译失败，请稍后再试" : "Translation failed. Please try again later." }
        var pickerTitle: String { return self.chinese ? "翻译成" : "Translate to" }
        var search: String { return self.chinese ? "搜索语言" : "Search languages" }
        var common: String { return self.chinese ? "常用语言" : "Frequently used" }
        var all: String { return self.chinese ? "所有语言" : "All languages" }
        var cancel: String { return self.chinese ? "取消" : "Cancel" }
        var noResults: String { return self.chinese ? "没有找到该语言" : "No languages found" }

        // specs#104
        var chatMenu: String { return self.chinese ? "发送前翻译…" : "Translate before sending…" }
        var turnOff: String { return self.chinese ? "关闭发送翻译" : "Turn off" }
        var turnedOff: String { return self.chinese ? "已关闭发送翻译" : "Translate before sending is off" }
        func turnedOn(_ language: String) -> String { return self.chinese ? "已开启发送翻译：发送前翻成\(language)" : "Translate before sending is on: messages go out in \(language)" }
        var translateAndSend: String { return self.chinese ? "翻译后发送…" : "Translate and send…" }
        var sendTranslation: String { return self.chinese ? "发送译文" : "Send translation" }
        var sendOriginal: String { return self.chinese ? "发送原文" : "Send original" }
        var edit: String { return self.chinese ? "编辑" : "Edit" }
        func previewTitle(_ language: String) -> String { return self.chinese ? "发送前预览 · \(language)" : "Preview · \(language)" }
        func failedSendOriginal(_ reason: String?) -> String { return (reason ?? self.failed) + (self.chinese ? "。要发送原文吗？" : ". Send the original instead?") }
        var capsuleHint: String { return self.chinese ? "发送前翻译：点这里改语言或关闭" : "Translate before sending: tap to change the language or turn it off" }

        func translatedTo(_ language: String) -> String {
            return self.chinese ? "已翻译成 \(language)" : "Translated to \(language)"
        }

        func languageName(_ code: String) -> String {
            let locale = Locale(identifier: self.chinese ? "zh-Hans" : "en")
            if let name = locale.localizedString(forLanguageCode: code), !name.isEmpty {
                return name.prefix(1).uppercased() + name.dropFirst()
            }
            return code
        }
    }

    static func ownLanguageName(_ code: String) -> String? {
        guard let name = Locale(identifier: code).localizedString(forLanguageCode: code), !name.isEmpty else {
            return nil
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: - Per chat language

    private struct StoredLanguage: Codable {
        let code: String
    }

    private struct StoredRecent: Codable {
        let codes: [String]
    }

    private static func chatKey(peerId: EnginePeer.Id) -> EngineDataBuffer {
        let key = EngineDataBuffer(length: 8)
        // Full peer id (namespace + id), so a user and a group/channel with the same numeric id don't share a language.
        // Same semantics as Android's dialogId key.
        key.setInt64(0, value: peerId.toInt64())
        return key
    }

    private static func recentKey() -> EngineDataBuffer {
        let key = EngineDataBuffer(length: 1)
        key.setInt8(0, value: 0)
        return key
    }

    static func savedLanguage(context: AccountContext, peerId: EnginePeer.Id) -> Signal<String?, NoError> {
        return context.engine.data.get(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.luckgramTranslateOut, id: chatKey(peerId: peerId)))
        |> map { entry -> String? in
            return entry?.get(StoredLanguage.self)?.code
        }
    }

    static func recentLanguages(context: AccountContext) -> Signal<[String], NoError> {
        return context.engine.data.get(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.luckgramTranslateOut, id: recentKey()))
        |> map { entry -> [String] in
            return entry?.get(StoredRecent.self)?.codes ?? []
        }
    }

    static func saveLanguage(context: AccountContext, peerId: EnginePeer.Id, code: String) {
        let engine = context.engine
        let collectionId = ApplicationSpecificItemCacheCollectionId.luckgramTranslateOut
        let _ = (recentLanguages(context: context)
        |> mapToSignal { recent -> Signal<Never, NoError> in
            var updated = recent.filter { $0 != code }
            updated.insert(code, at: 0)
            if updated.count > 5 {
                updated.removeLast(updated.count - 5)
            }
            return engine.itemCache.put(collectionId: collectionId, id: chatKey(peerId: peerId), item: StoredLanguage(code: code))
            |> then(engine.itemCache.put(collectionId: collectionId, id: recentKey(), item: StoredRecent(codes: updated)))
        }).startStandalone()
    }

    /// Saved choice for the chat, else the language detected in the peer's latest text message, else English.
    static func resolveLanguage(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?) -> Signal<String, NoError> {
        let accountPeerId = context.account.peerId
        let detected: Signal<String, NoError> = context.account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: threadId), index: .upperBound, anchorIndex: .upperBound, count: 32, fixedCombinedReadStates: nil)
        |> take(1)
        |> map { view, _, _ -> String in
            for entry in view.entries.reversed() {
                let message = entry.message
                if !message.effectivelyIncoming(accountPeerId) || message.text.isEmpty {
                    continue
                }
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(String(message.text.prefix(256)))
                if let language = recognizer.dominantLanguage, let code = normalize(language.rawValue) {
                    return code
                }
                return fallbackLanguage
            }
            return fallbackLanguage
        }
        |> timeout(3.0, queue: Queue.mainQueue(), alternate: .single(fallbackLanguage))

        return savedLanguage(context: context, peerId: peerId)
        |> mapToSignal { saved -> Signal<String, NoError> in
            if let saved {
                return .single(saved)
            }
            return detected
        }
    }

    static func normalize(_ code: String) -> String? {
        var code = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if code.isEmpty || code == "und" {
            return nil
        }
        if code.hasPrefix("zh") {
            return "zh"
        }
        if let dash = code.firstIndex(of: "-") {
            code = String(code[code.startIndex ..< dash])
        }
        if code == "nb" {
            code = "no"
        }
        return allLanguages.contains(code) ? code : nil
    }

    // MARK: - Translation

    enum Outcome {
        case translated(NSAttributedString)
        /// The reason to show (nil: the generic "translation failed").
        case failed(String?)
    }

    private enum TelegramOutcome {
        case translated(NSAttributedString)
        /// Telegram answered with an error (already written to the diagnostic log by TelegramCore).
        case error
        case empty
        case timedOut
    }

    /// Translates the composed text via messages.translateText. Emoji, custom emoji, mentions, links and line breaks
    /// are preserved; formatting is kept when the server returns it.
    ///
    /// specs#82: when Telegram fails (any error such as TRANSLATIONS_DISABLED_ALT, an empty result or no answer
    /// within LuckgramTranslateFallbackLogic.telegramTimeoutSeconds = 8 s) the plain text is translated by Luckgram AI instead; if that fails too, the outcome says why.
    static func translate(context: AccountContext, text: NSAttributedString, toLang: String) -> Signal<Outcome, NoError> {
        let string = text.string
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .single(.failed(nil))
        }
        // Formatting, text mentions and custom emoji from the field, plus plain @usernames / links / hashtags so the
        // translator leaves them untouched.
        let inputEntities = generateChatInputTextEntities(text)
        var entities = inputEntities
        for detected in generateTextEntities(string, enabledTypes: [.mention, .hashtag, .allUrl]) {
            let overlaps = inputEntities.contains(where: { existing in
                switch existing.type {
                case .Bold, .Italic, .Underline, .Strikethrough, .Spoiler, .BlockQuote:
                    return false // style entities may wrap a mention / link
                default:
                    return existing.range.overlaps(detected.range)
                }
            })
            if !overlaps {
                entities.append(detected)
            }
        }
        entities.sort(by: { $0.range.lowerBound < $1.range.lowerBound })

        let telegram: Signal<TelegramOutcome, NoError> = context.engine.messages.translate(text: string, toLang: toLang, entities: entities)
        |> map { result -> TelegramOutcome in
            guard let result, !result.0.isEmpty else {
                return .empty
            }
            return .translated(chatInputStateStringWithAppliedEntities(result.0, entities: result.1))
        }
        |> `catch` { _ -> Signal<TelegramOutcome, NoError> in
            return .single(.error)
        }
        |> timeout(LuckgramTranslateFallbackLogic.telegramTimeoutSeconds, queue: Queue.mainQueue(), alternate: .single(.timedOut))

        return telegram
        |> mapToSignal { outcome -> Signal<Outcome, NoError> in
            let source = LuckgramTranslateFallbackLogic.sourceOut
            switch outcome {
            case let .translated(result):
                return .single(.translated(result))
            case .timedOut:
                luckgramTranslationFallback?.logTelegramFailure(source: source, code: 0, text: LuckgramTranslateFallbackLogic.timeout)
            case .empty:
                luckgramTranslationFallback?.logTelegramFailure(source: source, code: 0, text: LuckgramTranslateFallbackLogic.emptyResult)
            case .error:
                break
            }
            guard let fallback = luckgramTranslationFallback else {
                return .single(.failed(nil))
            }
            return fallback.translate(source: source, text: string, toLang: toLang)
            |> map { translated -> Outcome in
                return .translated(chatInputStateStringWithAppliedEntities(translated, entities: []))
            }
            |> `catch` { error -> Signal<Outcome, NoError> in
                return .single(.failed(fallback.failureMessage(error)))
            }
        }
    }
}
