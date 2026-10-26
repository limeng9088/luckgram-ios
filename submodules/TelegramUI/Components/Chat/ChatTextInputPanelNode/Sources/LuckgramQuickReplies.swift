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
import LuckgramUI

public enum LuckgramQuickReplies {
    /// Switch key, registered in the Luckgram feature registry ("消息与语言" group). Default: on.
    public static let featureKey = "quick_replies"

    public static let maxCount = 100
    public static let maxLength = 1000

    /// Local switch on "Settings -> Luckgram features" and not switched off remotely (`LuckgramSettings`,
    /// feature 00). The default (on) comes from the registry.
    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(featureKey)
    }

    // MARK: - Strings

    public struct Strings {
        public let chinese: Bool

        /// Same rule as every other Luckgram string (`LuckgramStrings`, feature 00).
        public init(_ strings: PresentationStrings?) {
            self.chinese = LuckgramStrings.isChinese
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
        var editList: String { return self.chinese ? "编辑" : "Edit" }
        var delete: String { return self.chinese ? "删除" : "Delete" }
        var deleteConfirm: String { return self.chinese ? "删除这条快捷回复？" : "Delete this quick reply?" }
        var limitReached: String {
            return self.chinese ? "最多只能保存 \(LuckgramQuickReplies.maxCount) 条快捷回复" : "You can save up to \(LuckgramQuickReplies.maxCount) quick replies"
        }
        var manageInfo: String {
            return self.chinese
                ? "模板只保存在本机当前账号，不会上传。点按编辑，左滑删除，点「编辑」后拖动排序。每条最多 \(LuckgramQuickReplies.maxLength) 字，最多 \(LuckgramQuickReplies.maxCount) 条。"
                : "Templates are stored only on this device, for the current account, and are never uploaded. Tap to edit, swipe left to delete, tap Edit to reorder. Up to \(LuckgramQuickReplies.maxLength) characters each, \(LuckgramQuickReplies.maxCount) in total."
        }
        var ok: String { return self.chinese ? "好" : "OK" }
        var back: String { return self.chinese ? "返回" : "Back" }
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
