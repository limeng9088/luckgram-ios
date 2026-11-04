import Foundation
import Postbox
import SwiftSignalKit

/// Luckgram spec 01 A/B: translations shown inside a message bubble, below the original text (or
/// below a voice transcription). Kept per message until 「撤销翻译」, also across restarts (2000
/// entries, 7 days). Lives in TelegramCore so the bubble nodes can read it; LuckgramUI implements
/// the translating (`LuckgramTranslateInService`).
public final class LuckgramMessageTranslations {
    public static let shared = LuckgramMessageTranslations()

    public struct Entry: Equatable {
        public let text: String
        public let fromLang: String?
        public let toLang: String?
    }

    private let queue = Queue(name: "LuckgramMessageTranslations")
    private var cacheValue: LuckgramTranslateCache?
    private var saveScheduled = false
    private let lock = NSLock()

    private var fileURL: URL? {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("luckgram_translate_in.json")
    }

    private var cache: LuckgramTranslateCache {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.cacheValue {
            return value
        }
        let value = LuckgramTranslateCache.parse(self.fileURL.flatMap { try? Data(contentsOf: $0) }, now: Date().timeIntervalSince1970)
        self.cacheValue = value
        return value
    }

    private func key(accountPeerId: PeerId, messageId: MessageId, text: String, voice: Bool) -> String {
        return LuckgramTranslateInLogic.stateKey(account: accountPeerId.toInt64(), peerId: messageId.peerId.toInt64(), messageId: messageId.id, textKey: LuckgramTranslateCache.key(toLang: "", text: text), voice: voice)
    }

    public func entry(accountPeerId: PeerId, messageId: MessageId, text: String, voice: Bool = false) -> Entry? {
        guard let e = self.cache.get(self.key(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice), now: Date().timeIntervalSince1970) else {
            return nil
        }
        let langs = LuckgramTranslateInLogic.decodeLanguages(e.fromLang)
        return Entry(text: e.text, fromLang: langs.from, toLang: langs.to)
    }

    public func set(accountPeerId: PeerId, messageId: MessageId, text: String, voice: Bool = false, translated: String, fromLang: String?, toLang: String) {
        self.cache.put(self.key(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice), text: translated, fromLang: LuckgramTranslateInLogic.encodeLanguages(from: fromLang, to: toLang), now: Date().timeIntervalSince1970)
        self.scheduleSave()
    }

    public func remove(accountPeerId: PeerId, messageId: MessageId, text: String, voice: Bool = false) {
        // An expired entry is a removed one.
        self.cache.put(self.key(accountPeerId: accountPeerId, messageId: messageId, text: text, voice: voice), text: " ", fromLang: nil, now: 0)
        self.scheduleSave()
    }

    private func scheduleSave() {
        self.lock.lock()
        if self.saveScheduled {
            self.lock.unlock()
            return
        }
        self.saveScheduled = true
        self.lock.unlock()
        self.queue.after(1.5) { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            self.saveScheduled = false
            self.lock.unlock()
            guard let url = self.fileURL else {
                return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? self.cache.serialize(now: Date().timeIntervalSince1970).write(to: url, options: .atomic)
        }
    }
}

/// Luckgram spec 01 A/B: translating a message in its bubble. Implemented in LuckgramUI
/// (`LuckgramTranslateInController`) and installed by the app; nil in extensions.
public protocol LuckgramTranslateInService: AnyObject {
    /// `translate_in` is on.
    var isEnabled: Bool { get }
    /// spec 01 A.2: whether the one-tap button shows next to an incoming message with this text.
    func showButton(text: String, accountPeerId: PeerId, peerId: PeerId) -> Bool
    /// spec 01 B.2: whether 「翻译」 shows under a transcription with this text.
    func showVoiceLink(text: String, accountPeerId: PeerId, peerId: PeerId) -> Bool
    /// specs#105 §1: the 「🌐 中文 ▾」 button after the header (same tap as the header).
    func languageButton(toLang: String?) -> String
    /// spec 01 A.1: header line of a translation, e.g. 「已翻译 · 英语 → 中文」.
    func header(fromLang: String?, toLang: String?) -> String
    /// Translates the message's `text` (or removes its translation); `updated` runs on the main
    /// queue when the bubble should be redrawn. Failures are shown to the user by the service.
    func toggle(accountPeerId: PeerId, messageId: MessageId, text: String, voice: Bool, updated: @escaping () -> Void)
    /// specs#93 / #105: the header or its language button was tapped (or the one-tap button long-pressed):
    /// pick another language (this chat only or the default) and translate this message again.
    func changeLanguage(accountPeerId: PeerId, messageId: MessageId, text: String, voice: Bool, updated: @escaping () -> Void)
}

public var luckgramTranslateIn: LuckgramTranslateInService?

/// specs#93: attribute on the 「已翻译 · 英语 → 中文」 header in a bubble; a tap changes the language.
public let luckgramTranslateHeaderKey = NSAttributedString.Key(rawValue: "LuckgramTranslateHeader")
