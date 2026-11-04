import Foundation

/// Luckgram spec 01 A: rules of translating received messages inside the bubble. Foundation only,
/// unit tested on Linux; same rules as Android `org.telegram.luckgram.translatein.TranslateInLogic`.
public enum LuckgramTranslateInLogic {
    /// Feature switch (spec 01 「开关」): received-message translation incl. the one-tap button.
    public static let featureKey = "translate_in"

    /// Language code reduced to what decides "same language": lower case, no region; nb/nn are no.
    public static func base(_ lang: String?) -> String? {
        guard let lang else {
            return nil
        }
        var s = lang.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if s.isEmpty || s == "und" {
            return nil
        }
        if let dash = s.firstIndex(of: "-"), dash != s.startIndex {
            s = String(s[s.startIndex ..< dash])
        }
        if s == "nb" || s == "nn" {
            return "no"
        }
        return s
    }

    /// Whether `lang` is one of the "don't translate" languages (compared by `base`).
    public static func isExcluded(_ lang: String?, doNotTranslate: [String]) -> Bool {
        guard let b = base(lang) else {
            return false
        }
        return doNotTranslate.contains(where: { base($0) == b })
    }

    /// spec 01 A.2/A.3: the one-tap button shows next to someone else's message with text whose
    /// detected language is known and not a "don't translate" language (nor the target).
    public static func showButton(featureOn: Bool, outgoing: Bool, hasText: Bool, detectedLang: String?, doNotTranslate: [String], toLang: String?) -> Bool {
        if !featureOn || outgoing || !hasText {
            return false
        }
        guard let b = base(detectedLang) else {
            return false
        }
        if b == base(toLang) {
            return false
        }
        return !isExcluded(b, doNotTranslate: doNotTranslate)
    }

    /// The target language the user chose, or nil before the first choice (specs#93: no default from
    /// the app / system language; the first translation asks).
    public static func targetLanguage(chosen: String?) -> String? {
        if let chosen = chosen?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty {
            return chosen
        }
        return nil
    }

    /// specs#105: the language a chat translates into — its own choice, else the default, else nil (nothing
    /// chosen yet: the first translation asks).
    public static func effectiveLanguage(chatChosen: String?, defaultChosen: String?) -> String? {
        return targetLanguage(chosen: chatChosen) ?? targetLanguage(chosen: defaultChosen)
    }

    /// specs#105: the language button next to a translation's header, e.g. 「🌐 中文 ▾」.
    public static func languageButton(toName: String) -> String {
        return "\u{1F310} " + toName + " \u{25BE}"
    }

    /// specs#105 §3: puts `code` first in the recently used languages (max 5), stored comma separated.
    public static func updatingRecent(_ stored: String?, code: String) -> String {
        var list = (stored ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty && $0 != code }
        list.insert(code, at: 0)
        return list.prefix(5).joined(separator: ",")
    }

    /// spec 01 A.1: 「已翻译 · 英语 → 中文」; without a known source just the target.
    public static func header(fromName: String?, toName: String, chinese: Bool) -> String {
        let prefix = chinese ? "已翻译 · " : "Translated · "
        if let fromName, !fromName.isEmpty {
            return prefix + fromName + " → " + toName
        }
        return prefix + toName
    }

    /// Long-press menu label: 「翻译」, or 「撤销翻译」 when the message shows a translation.
    public static func menuLabel(translated: Bool, chinese: Bool) -> String {
        if translated {
            return chinese ? "撤销翻译" : "Undo translation"
        }
        return chinese ? "翻译" : "Translate"
    }

    /// Key of a message's translation state: per account, chat, message and text, so an edited
    /// message loses its (stale) translation; voice transcriptions have their own.
    public static func stateKey(account: Int64, peerId: Int64, messageId: Int32, textKey: String, voice: Bool) -> String {
        return (voice ? "v" : "") + "\(account):\(peerId):\(messageId):\(textKey)"
    }

    /// The "from>to" languages kept with a saved translation.
    public static func encodeLanguages(from: String?, to: String?) -> String {
        return (from ?? "") + ">" + (to ?? "")
    }

    /// Inverse of `encodeLanguages`.
    public static func decodeLanguages(_ value: String?) -> (from: String?, to: String?) {
        guard let value else {
            return (nil, nil)
        }
        let parts = value.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let from = parts.first ?? ""
        let to = parts.count > 1 ? parts[1] : ""
        return (from.isEmpty ? nil : from, to.isEmpty ? nil : to)
    }
}
