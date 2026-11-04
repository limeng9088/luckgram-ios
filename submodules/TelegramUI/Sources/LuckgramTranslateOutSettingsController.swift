// Luckgram specs#104 §3/§6: settings of translate before sending (secondary page of the translate_out
// switch): preview on/off and the chats where 「发送翻译」 is on.

import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import Display
import AccountContext
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import ChatTextInputPanelNode
import LuckgramUI

private final class LuckgramTranslateOutSettingsArguments {
    let togglePreview: (Bool) -> Void
    let turnOff: (EnginePeer.Id) -> Void
    let turnOffAll: () -> Void

    init(togglePreview: @escaping (Bool) -> Void, turnOff: @escaping (EnginePeer.Id) -> Void, turnOffAll: @escaping () -> Void) {
        self.togglePreview = togglePreview
        self.turnOff = turnOff
        self.turnOffAll = turnOffAll
    }
}

private enum LuckgramTranslateOutSettingsEntry: ItemListNodeEntry {
    case preview(String, Bool)
    case previewInfo(String)
    case chatsHeader(String)
    case chat(Int32, EnginePeer.Id, String, String)
    case offAll(String)
    case info(String)

    var section: ItemListSectionId {
        switch self {
        case .preview, .previewInfo:
            return 0
        default:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .preview:
            return 0
        case .previewInfo:
            return 1
        case .chatsHeader:
            return 2
        case let .chat(index, _, _, _):
            return 100 + index
        case .offAll:
            return 100000
        case .info:
            return 100001
        }
    }

    static func <(lhs: LuckgramTranslateOutSettingsEntry, rhs: LuckgramTranslateOutSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: LuckgramTranslateOutSettingsEntry, rhs: LuckgramTranslateOutSettingsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.preview(a, b), .preview(c, d)):
            return a == c && b == d
        case let (.previewInfo(a), .previewInfo(b)), let (.chatsHeader(a), .chatsHeader(b)), let (.offAll(a), .offAll(b)), let (.info(a), .info(b)):
            return a == b
        case let (.chat(a, b, c, d), .chat(e, f, g, h)):
            return a == e && b == f && c == g && d == h
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramTranslateOutSettingsArguments
        switch self {
        case let .preview(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.togglePreview(value)
            })
        case let .previewInfo(text), let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .chatsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .chat(_, peerId, title, language):
            // tap: turn it off for this chat (its language stays saved for next time)
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: language, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.turnOff(peerId)
            })
        case let .offAll(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.turnOffAll()
            })
        }
    }
}

private func luckgramLanguageDisplayName(_ code: String) -> String {
    let locale = Locale(identifier: LuckgramStrings.isChinese ? "zh-Hans" : "en")
    let base = LuckgramSendTranslateLogic.base(code) ?? code
    return locale.localizedString(forLanguageCode: base) ?? code
}

func luckgramTranslateOutSettingsController(context: AccountContext) -> ViewController {
    let s: (String, String) -> String = { zh, en in LuckgramStrings.isChinese ? zh : en }
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    let refresh = {
        version += 1
        updated.set(version)
    }

    let arguments = LuckgramTranslateOutSettingsArguments(togglePreview: { value in
        LuckgramTranslateOut.previewEnabled = value
        refresh()
    }, turnOff: { peerId in
        LuckgramTranslateOut.setChat(context: context, peerId: peerId, on: nil)
        refresh()
    }, turnOffAll: {
        for item in LuckgramTranslateOut.chatsOn(context: context) {
            LuckgramTranslateOut.setChat(context: context, peerId: item.peerId, on: nil)
        }
        refresh()
    })

    let chats: Signal<[(EnginePeer.Id, String, String)], NoError> = updated.get()
    |> mapToSignal { _ -> Signal<[(EnginePeer.Id, String, String)], NoError> in
        let on = LuckgramTranslateOut.chatsOn(context: context)
        return context.engine.data.get(EngineDataMap(on.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0.peerId) }))
        |> map { peers -> [(EnginePeer.Id, String, String)] in
            return on.map { item in
                let title = peers[item.peerId].flatMap { $0 }.map { $0.displayTitle(strings: context.sharedContext.currentPresentationData.with { $0 }.strings, displayOrder: .firstLast) } ?? String(item.peerId.id._internalGetInt64Value())
                return (item.peerId, title, luckgramLanguageDisplayName(item.language))
            }
        }
    }

    let signal = combineLatest(queue: Queue.mainQueue(), context.sharedContext.presentationData, chats)
    |> map { presentationData, chats -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [LuckgramTranslateOutSettingsEntry] = [
            .preview(s("发送前预览译文", "Preview before sending"), LuckgramTranslateOut.previewEnabled),
            .previewInfo(s("关掉后直接发送译文，不再弹出预览。", "When off, the translation is sent right away without a preview.")),
            .chatsHeader(s("已开启发送翻译的聊天", "Chats with translate before sending").uppercased())
        ]
        if chats.isEmpty {
            entries.append(.info(s("还没有聊天开启。在聊天菜单或输入框「+」里选「发送前翻译…」。", "None yet. Open a chat's menu or the input field's + and choose Translate before sending…")))
        } else {
            for (index, chat) in chats.enumerated() {
                entries.append(.chat(Int32(index), chat.0, chat.1, chat.2))
            }
            entries.append(.offAll(s("全部关闭", "Turn off for all chats")))
            entries.append(.info(s("点某个聊天即可关闭；在聊天里点输入框的「中 → EN」可改语言。", "Tap a chat to turn it off; in a chat, tap the \"中 → EN\" capsule to change the language.")))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(s("发送前翻译", "Translate before sending")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}
