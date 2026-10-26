// Luckgram: translate the message being composed before it is sent (feature 01, "translate_out").
//
// Translation goes through Telegram's own messages.translateText; nothing is sent anywhere else.
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

    /// Translates the composed text via messages.translateText. Emoji, custom emoji, mentions, links and line breaks
    /// are preserved; formatting is kept when the server returns it. Emits nil on failure.
    static func translate(context: AccountContext, text: NSAttributedString, toLang: String) -> Signal<NSAttributedString?, NoError> {
        let string = text.string
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .single(nil)
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

        return context.engine.messages.translate(text: string, toLang: toLang, entities: entities)
        |> map { result -> NSAttributedString? in
            guard let result, !result.0.isEmpty else {
                return nil
            }
            return chatInputStateStringWithAppliedEntities(result.0, entities: result.1)
        }
        |> `catch` { _ -> Signal<NSAttributedString?, NoError> in
            return .single(nil)
        }
        |> timeout(15.0, queue: Queue.mainQueue(), alternate: .single(nil))
    }
}
