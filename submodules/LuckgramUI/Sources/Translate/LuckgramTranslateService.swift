import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext
import UndoUI

/// Luckgram spec 01: Luckgram AI as the fallback translator when Telegram's translation fails
/// (translate-before-sending, long-press "Translate"). Results are cached (spec 01 「翻译服务」5). Installed into
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

    private static let cacheQueue = Queue(name: "LuckgramTranslateCache")
    /// Guards `cacheValue` and `saveScheduled`: `cache` / `remember` are called from the main queue, the save
    /// runs on `cacheQueue`, and Telegram translate callbacks may arrive on other queues.
    private static let stateLock = NSLock()
    private static var cacheValue: LuckgramTranslateCache?
    private static var saveScheduled = false

    private static var cacheURL: URL? {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("luckgram_translate_cache.json")
    }

    /// spec 01 「翻译服务」5: the shared result cache (2000 entries, 7 days), loaded once on first use (thread-safe).
    public static var cache: LuckgramTranslateCache {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let value = cacheValue {
            return value
        }
        let value = LuckgramTranslateCache.parse(cacheURL.flatMap { try? Data(contentsOf: $0) }, now: Date().timeIntervalSince1970)
        cacheValue = value
        return value
    }

    /// The cached translation of `text` into `toLang`, or nil.
    public static func cached(toLang: String, text: String) -> LuckgramTranslateCache.Entry? {
        return cache.get(LuckgramTranslateCache.key(toLang: toLang, text: text), now: Date().timeIntervalSince1970)
    }

    /// Stores a translation and writes the cache file a little later (batched).
    public static func remember(toLang: String, text: String, translated: String, fromLang: String?) {
        cache.put(LuckgramTranslateCache.key(toLang: toLang, text: text), text: translated, fromLang: fromLang, now: Date().timeIntervalSince1970)
        stateLock.lock()
        let alreadyScheduled = saveScheduled
        saveScheduled = true
        stateLock.unlock()
        if alreadyScheduled {
            return
        }
        cacheQueue.after(2.0) {
            stateLock.lock()
            saveScheduled = false
            stateLock.unlock()
            guard let url = cacheURL else {
                return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? cache.serialize(now: Date().timeIntervalSince1970).write(to: url, options: .atomic)
        }
    }

    public static func install(context: @escaping () -> AccountContext?, present: @escaping (ViewController) -> Void) {
        luckgramTranslationFallback = LuckgramTranslateService(context: context, present: present)
    }

    public func translate(source: String, text: String, toLang: String) -> Signal<String, LuckgramTranslationFallbackError> {
        guard let lang = LuckgramTranslateFallbackLogic.aiLanguage(toLang), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail(LuckgramTranslationFallbackError(code: LuckgramAIError.invalidRequest))
        }
        if let hit = LuckgramTranslateService.cached(toLang: lang, text: text) {
            return .single(hit.text)
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
            |> deliverOnMainQueue
            |> map { translation -> String in
                LuckgramTranslateService.remember(toLang: lang, text: text, translated: translation.text, fromLang: LuckgramTranslateFallbackLogic.aiLanguage(translation.fromLang))
                return translation.text
            }
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
