// Luckgram: quick reply templates (feature 02, "quick_replies").
//
// Templates are stored locally in the account's postbox item cache (removed together with the account data on
// logout) and never uploaded. Unrelated to Telegram Business "quick replies" (cloud shortcuts), which stay untouched.

import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences

public enum LuckgramQuickReplies {
    /// Switch key, registered in the Luckgram feature registry ("消息与语言" group). Default: on.
    public static let featureKey = "quick_replies"
    public static let featureDefault = true

    public static let maxCount = 100
    public static let maxLength = 1000

    /// Device level switch shared by all accounts. Same storage as feature 00's `LuckgramSettings`
    /// (`UserDefaults(suiteName: "luckgram_settings")`, key = feature key; unset = registry default).
    /// Android: `SharedPreferences("luckgram_settings")`.
    public static var isEnabled: Bool {
        if let value = UserDefaults(suiteName: "luckgram_settings")?.object(forKey: featureKey) as? Bool {
            return value
        }
        return featureDefault
    }

    // MARK: - Strings

    public struct Strings {
        public let chinese: Bool

        public init(_ strings: PresentationStrings?) {
            if let code = strings?.baseLanguageCode.lowercased(), code.hasPrefix("zh") {
                self.chinese = true
            } else {
                self.chinese = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
            }
        }

        var presets: [String] {
            if self.chinese {
                return ["在路上了！", "10 分钟后给你回电话可以吗？", "谢谢，收到。", "抱歉，要晚 5 分钟！"]
            }
            return ["On my way!", "Can I call you back in 10 minutes?", "Thanks, got it.", "Sorry, I'll be 5 minutes late!"]
        }

        public var title: String { return self.chinese ? "快捷回复" : "Quick replies" }
        var manage: String { return self.chinese ? "管理" : "Manage" }
        var hint: String { return self.chinese ? "点按填入输入框，长按直接发送" : "Tap to insert, long press to send" }
        var empty: String { return self.chinese ? "还没有快捷回复" : "No quick replies yet" }
        var add: String { return self.chinese ? "添加快捷回复" : "Add quick reply" }
        var edit: String { return self.chinese ? "编辑快捷回复" : "Edit quick reply" }
        var placeholder: String { return self.chinese ? "输入回复内容" : "Reply text" }
        var save: String { return self.chinese ? "保存" : "Save" }
        var cancel: String { return self.chinese ? "取消" : "Cancel" }
        var done: String { return self.chinese ? "完成" : "Done" }
        var delete: String { return self.chinese ? "删除" : "Delete" }
        var deleteConfirm: String { return self.chinese ? "删除这条快捷回复？" : "Delete this quick reply?" }
        var limitReached: String {
            return self.chinese ? "最多只能保存 \(LuckgramQuickReplies.maxCount) 条快捷回复" : "You can save up to \(LuckgramQuickReplies.maxCount) quick replies"
        }
        var manageInfo: String {
            return self.chinese
                ? "模板只保存在本机当前账号，不会上传。拖动右侧手柄排序，点按编辑，左滑删除。每条最多 \(LuckgramQuickReplies.maxLength) 字，最多 \(LuckgramQuickReplies.maxCount) 条。"
                : "Templates are stored on this device for the current account only and never uploaded. Drag the handle to reorder, tap to edit, swipe to delete. Up to \(LuckgramQuickReplies.maxLength) characters each, \(LuckgramQuickReplies.maxCount) in total."
        }
        var ok: String { return self.chinese ? "好" : "OK" }
    }

    // MARK: - Storage

    private struct Stored: Codable {
        let items: [String]
    }

    private static func key() -> EngineDataBuffer {
        let key = EngineDataBuffer(length: 1)
        key.setInt8(0, value: 0)
        return key
    }

    /// Templates of the account in user order. Seeds the 4 examples on first use.
    public static func items(context: AccountContext) -> Signal<[String], NoError> {
        let engine = context.engine
        let presets = Strings(context.sharedContext.currentPresentationData.with { $0 }.strings).presets
        return engine.data.get(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.luckgramQuickReplies, id: key()))
        |> mapToSignal { entry -> Signal<[String], NoError> in
            if let stored = entry?.get(Stored.self) {
                return .single(stored.items)
            }
            let _ = engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.luckgramQuickReplies, id: key(), item: Stored(items: presets)).startStandalone()
            return .single(presets)
        }
    }

    public static func setItems(context: AccountContext, items: [String]) {
        let _ = context.engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.luckgramQuickReplies, id: key(), item: Stored(items: Array(items.prefix(maxCount)))).startStandalone()
    }

    /// Templates starting with `query` (case insensitive), for the "/" suggestions.
    public static func search(context: AccountContext, query: String) -> Signal<[String], NoError> {
        if !isEnabled {
            return .single([])
        }
        let query = query.lowercased()
        return items(context: context)
        |> map { items -> [String] in
            return items.filter { $0.lowercased().hasPrefix(query) }
        }
    }

    public static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return String(trimmed.prefix(maxLength))
    }
}
