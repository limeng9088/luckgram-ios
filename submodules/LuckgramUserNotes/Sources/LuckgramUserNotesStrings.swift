// Luckgram — private notes (spec 05).
// Licensed under GNU GPL v. 2 or later.

import Foundation
import TelegramPresentationData
import LuckgramUI

/// Chinese / English UI strings for private notes.
///
/// Telegram's language packs have no keys for Luckgram features, so the strings live here; the
/// Chinese / English choice is the shared Luckgram rule `LuckgramStrings.isChinese` (specs#42).
public struct LuckgramUserNotesStrings {
    public let isChinese: Bool

    public init(strings: PresentationStrings) {
        let _ = strings
        self.isChinese = LuckgramStrings.isChinese
    }

    private func s(_ en: String, _ zh: String) -> String {
        return self.isChinese ? zh : en
    }

    public var rowTitle: String { return s("Private note", "私人备注") }
    public var onlyYou: String { return s("only visible to you", "只有你能看到") }
    public var addNote: String { return s("Add a note…", "添加备注…") }

    public var editTitle: String { return s("Private note", "私人备注") }
    public var editPlaceholder: String { return s("Write something only you can see", "写点只有你能看到的内容") }
    public var editInfo: String { return s("Only you can see this note. It is stored on this device for the current account and is never uploaded.", "只有你能看到这条备注。它只保存在这台设备的当前账号中，不会上传。") }
    public var deleteNote: String { return s("Delete note", "删除备注") }
    public var deleteConfirm: String { return s("Delete this note?", "确定删除这条备注吗？") }
    public var delete: String { return s("Delete", "删除") }
    public var cancel: String { return s("Cancel", "取消") }
    public var done: String { return s("Done", "完成") }
    public var discardTitle: String { return s("Discard changes?", "放弃修改？") }
    public var discard: String { return s("Discard", "放弃") }
    public var tooLong: String { return s("A note can be up to 2000 characters", "备注最多 2000 字") }

    public var barTitle: String { return s("Private note · only visible to you", "私人备注 · 只有你能看到") }
    public var edit: String { return s("Edit", "编辑") }
    public var expand: String { return s("Show note", "展开备注") }
    public var collapse: String { return s("Collapse", "收起") }

    public var allNotes: String { return s("All notes", "全部备注") }
    public var searchPlaceholder: String { return s("Search notes or names", "搜索备注或名字") }
    public var noNotes: String { return s("No notes yet. Open a profile and tap “Add a note…”.", "还没有备注。打开资料页，点击「添加备注…」即可添加。") }
    public var noResults: String { return s("No results", "没有找到结果") }
}
