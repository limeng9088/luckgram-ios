// Luckgram — select all messages from one sender (spec 14).
//
// "Select All from <name>" in the message context menu enters multi-select with the long-pressed
// message and then pages through messages.search(from_id) (via TelegramEngine.searchMessages),
// adding every page to the selection. iOS selection has no 100 cap. Leaving selection cancels.

import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import Display
import AccountContext
import UndoUI
import Pasteboard
import LuckgramUI

enum LuckgramSelectAll {
    static let settingKey = "select_all_from_sender"

    static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(settingKey)
    }

    /// Menu title: "全选 Noah 的消息"; in private chats "全选对方的消息" / "全选我的消息".
    static func menuTitle(chatPeerId: EnginePeer.Id, author: EnginePeer, accountPeerId: EnginePeer.Id) -> String {
        if chatPeerId.namespace == Namespaces.Peer.CloudUser || chatPeerId.namespace == Namespaces.Peer.SecretChat {
            return author.id == accountPeerId
                ? LuckgramStrings.pick("全选我的消息", "Select All My Messages")
                : LuckgramStrings.pick("全选对方的消息", "Select All Their Messages")
        }
        let name = author.id == accountPeerId ? LuckgramStrings.pick("我", "Me") : author.compactDisplayTitle
        return LuckgramStrings.pick("全选 \(name) 的消息", "Select All from \(name)")
    }

    static var loadingText: String { LuckgramStrings.pick("正在加载全部消息，退出多选可取消", "Loading all messages… Leave selection to cancel") }
    static func doneText(_ count: Int) -> String { LuckgramStrings.pick("已选中全部 \(count) 条", "All \(count) messages selected") }
    static func failedText(_ count: Int) -> String { LuckgramStrings.pick("加载中断，已选中 \(count) 条", "Loading stopped, \(count) selected") }
    static func cantDeleteText(_ count: Int) -> String { LuckgramStrings.pick("有 \(count) 条消息你没有权限删除，已跳过", "\(count) messages can't be deleted by you and were skipped") }
    static var copyText: String { LuckgramStrings.pick("复制文字", "Copy Text") }
    static var copiedText: String { LuckgramStrings.pick("已按时间顺序复制", "Copied in chronological order") }
}

extension ChatControllerImpl {
    /// Called right after the context-menu item put the long-pressed message into selection.
    func luckgramStartSelectAll(senderId: EnginePeer.Id) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        self.luckgramSelectAllDisposable.set(nil)
        self.luckgramSelectAllActive = true

        if peerId.namespace == Namespaces.Peer.SecretChat {
            // Secret chats: only the messages on this device.
            let ids = self.chatDisplayNode.historyNode.luckgramLoadedMessages().filter { $0.author?.id == senderId }.map { $0.id }
            self.luckgramAddToSelection(ids)
            self.luckgramPresentToast(LuckgramSelectAll.doneText(self.presentationInterfaceState.interfaceState.selectionState?.selectedIds.count ?? 0), withCopy: true)
            return
        }
        // Broadcast channels: every post is "from" the channel, so select all posts.
        let fromId: EnginePeer.Id? = senderId == peerId ? nil : senderId
        let location: SearchMessagesLocation = .peer(peerId: peerId, fromId: fromId, tags: nil, reactions: nil, threadId: self.chatLocation.threadId, minDate: nil, maxDate: nil)
        self.luckgramPresentToast(LuckgramSelectAll.loadingText, withCopy: false)
        self.luckgramLoadSelectAllPage(location: location, state: nil, loadedSoFar: 0)
    }

    private func luckgramLoadSelectAllPage(location: SearchMessagesLocation, state: SearchMessagesState?, loadedSoFar: Int) {
        // `result.messages` accumulates over pages (the state carries the previous ones).
        self.luckgramSelectAllDisposable.set((self.context.engine.messages.searchMessages(location: location, query: "", state: state, limit: 100)
        |> take(1)
        |> deliverOnMainQueue).startStrict(next: { [weak self] result, nextState in
            guard let self, self.luckgramSelectAllActive, self.presentationInterfaceState.interfaceState.selectionState != nil else {
                return
            }
            let alreadySelected = self.presentationInterfaceState.interfaceState.selectionState?.selectedIds ?? Set()
            var newMessages: [EngineMessage] = []
            for message in result.messages {
                let message = EngineMessage(message)
                if message.media.contains(where: { $0 is TelegramMediaAction }) || alreadySelected.contains(message.id) {
                    continue
                }
                newMessages.append(message)
            }
            // Search results are only rendered, not stored; forward / copy / delete look messages up
            // in Postbox, so store the page first (same as opening a search result).
            self.context.engine.messages.ensureMessagesAreLocallyAvailable(messages: newMessages)
            self.luckgramAddToSelection(newMessages.map { $0.id })
            let count = self.presentationInterfaceState.interfaceState.selectionState?.selectedIds.count ?? 0
            if result.completed || result.messages.count <= loadedSoFar {
                self.luckgramPresentToast(LuckgramSelectAll.doneText(count), withCopy: true)
            } else {
                self.luckgramLoadSelectAllPage(location: location, state: nextState, loadedSoFar: result.messages.count)
            }
        }))
    }

    func luckgramStopSelectAll() {
        self.luckgramSelectAllDisposable.set(nil)
        self.luckgramSelectAllActive = false
    }

    private func luckgramAddToSelection(_ ids: [EngineMessage.Id]) {
        if ids.isEmpty || self.presentationInterfaceState.interfaceState.selectionState == nil {
            return
        }
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withToggledSelectedMessages(ids, value: true) } })
    }

    private func luckgramPresentToast(_ text: String, withCopy: Bool) {
        self.dismissAllUndoControllers()
        self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: text, timeout: withCopy ? 6.0 : nil, customUndoText: withCopy ? LuckgramSelectAll.copyText : nil), elevatedLayout: true, action: { [weak self] action in
            if case .undo = action {
                self?.luckgramCopySelected()
            }
            return false
        }), in: .current)
    }

    /// Copies the text of the selected messages, oldest first (spec 14 requirement 4).
    func luckgramCopySelected() {
        guard let ids = self.presentationInterfaceState.interfaceState.selectionState?.selectedIds, !ids.isEmpty else {
            return
        }
        let _ = (self.context.engine.data.get(EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Messages.Message.init(id:))))
        |> deliverOnMainQueue).startStandalone(next: { [weak self] messages in
            guard let self else {
                return
            }
            let sorted = messages.values.compactMap { $0 }.sorted(by: { $0.index < $1.index })
            let text = sorted.map { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if text.isEmpty {
                return
            }
            storeMessageTextInPasteboard(text, entities: nil)
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .copy(text: LuckgramSelectAll.copiedText), elevatedLayout: true, action: { _ in return false }), in: .current)
        })
    }

    /// Spec 14: in select-all mode delete only what we may delete and say how many were skipped.
    func luckgramPrepareDelete(_ messageIds: Set<EngineMessage.Id>, completion: @escaping (Set<EngineMessage.Id>) -> Void) {
        guard self.luckgramSelectAllActive, let peerId = self.chatLocation.peerId else {
            completion(messageIds)
            return
        }
        let accountPeerId = self.context.account.peerId
        let _ = (self.context.engine.data.get(
            TelegramEngine.EngineData.Item.Peer.Peer(id: peerId),
            EngineDataMap(messageIds.map(TelegramEngine.EngineData.Item.Messages.Message.init(id:)))
        )
        |> deliverOnMainQueue).startStandalone(next: { [weak self] peer, messages in
            guard let self else {
                return
            }
            var canDeleteOthers = true
            if case let .channel(channel) = peer {
                canDeleteOthers = channel.hasPermission(.deleteAllMessages)
            } else if case let .legacyGroup(group) = peer {
                switch group.role {
                case .creator, .admin:
                    canDeleteOthers = true
                case .member:
                    canDeleteOthers = false
                }
            }
            if canDeleteOthers {
                completion(messageIds)
                return
            }
            var deletable = Set<EngineMessage.Id>()
            for (id, message) in messages {
                if let message, message.author?.id == accountPeerId || !message.flags.contains(.Incoming) {
                    deletable.insert(id)
                }
            }
            let skipped = messageIds.count - deletable.count
            if skipped > 0 {
                let removed = Array(messageIds.subtracting(deletable))
                self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withToggledSelectedMessages(removed, value: false) } })
                self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: LuckgramSelectAll.cantDeleteText(skipped), timeout: nil, customUndoText: nil), elevatedLayout: true, action: { _ in return false }), in: .current)
            }
            if !deletable.isEmpty {
                completion(deletable)
            }
        })
    }
}
