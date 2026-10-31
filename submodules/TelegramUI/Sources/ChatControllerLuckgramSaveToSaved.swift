// Luckgram — save a message to Saved Messages in one tap (spec 15).
//
// "Save" in the message context menu (right below Forward) and in the multi-select panel
// (left of Forward). It forwards to the account's own chat exactly like a normal forward, so the
// original sender is kept. Same rules and wording as Android `SaveToSaved`.

import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import Display
import AccountContext
import UndoUI
import ChatPresentationInterfaceState
import ChatControllerInteraction
import LuckgramUI

enum LuckgramSaveToSaved {
    static let settingKey = "save_to_saved"

    static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(settingKey)
    }

    /// Offered at all in this chat: switch on, not Saved Messages itself, not a secret chat,
    /// and the chat does not forbid forwarding (protected content).
    static func isAvailable(chatPresentationInterfaceState: ChatPresentationInterfaceState, accountPeerId: EnginePeer.Id) -> Bool {
        guard isEnabled, let peerId = chatPresentationInterfaceState.chatLocation.peerId else {
            return false
        }
        if peerId == accountPeerId || peerId.namespace == Namespaces.Peer.SecretChat {
            return false
        }
        if chatPresentationInterfaceState.copyProtectionEnabled {
            return false
        }
        if case .scheduledMessages = chatPresentationInterfaceState.subject {
            return false
        }
        return true
    }

    static var menuTitle: String { LuckgramStrings.pick("收藏", "Save") }
    static var savedText: String { LuckgramStrings.pick("已保存到收藏夹", "Saved to Saved Messages") }
    static var viewText: String { LuckgramStrings.pick("查看", "View") }

    /// Bookmark glyph at context-menu size (the bundled one is 30 pt).
    static func menuIcon(color: UIColor) -> UIImage? {
        guard let image = UIImage(bundleImageName: "Instant View/Bookmark") else {
            return nil
        }
        return generateTintedImage(image: generateScaledImage(image: image, size: CGSize(width: 24.0, height: 24.0), opaque: false), color: color)
    }
}

/// Selection-panel hook: nil (button hidden) unless "Save" is available in this chat.
func luckgramSaveSelectedAction(context: AccountContext, chatPresentationInterfaceState: ChatPresentationInterfaceState, chatControllerInteraction: ChatControllerInteraction?) -> (() -> Void)? {
    guard LuckgramSaveToSaved.isAvailable(chatPresentationInterfaceState: chatPresentationInterfaceState, accountPeerId: context.account.peerId) else {
        return nil
    }
    guard let chatController = (chatControllerInteraction?.chatControllerNode() as? ChatControllerNode)?.luckgramController else {
        return nil
    }
    return { [weak chatController] in
        guard let chatController, let ids = chatController.presentationInterfaceState.interfaceState.selectionState?.selectedIds, !ids.isEmpty else {
            return
        }
        chatController.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
        chatController.luckgramSaveToSaved(Array(ids))
    }
}

extension ChatControllerImpl {
    /// Forwards `messageIds` to Saved Messages, oldest first, then shows "Saved · View".
    func luckgramSaveToSaved(_ messageIds: [EngineMessage.Id]) {
        let accountPeerId = self.context.account.peerId
        let _ = (self.context.engine.data.get(EngineDataMap(messageIds.map(TelegramEngine.EngineData.Item.Messages.Message.init(id:))))
        |> deliverOnMainQueue).startStandalone(next: { [weak self] messages in
            guard let self else {
                return
            }
            let sorted = messages.values.compactMap { $0 }.filter { !$0._asMessage().isCopyProtected() }.sorted(by: { $0.index < $1.index })
            if sorted.isEmpty {
                return
            }
            let enqueued: [EnqueueMessage] = sorted.map { message in
                return .forward(source: message.id, threadId: nil, grouping: .auto, attributes: [], correlationId: nil)
            }
            let _ = enqueueMessages(account: self.context.account, peerId: accountPeerId, messages: enqueued).startStandalone()

            self.chatDisplayNode.hapticFeedback.success()
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            self.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: LuckgramSaveToSaved.savedText, timeout: nil, customUndoText: LuckgramSaveToSaved.viewText), elevatedLayout: false, position: .top, animateInAsReplacement: true, action: { [weak self] action in
                guard case .undo = action, let self else {
                    return false
                }
                // The saved copy is the newest message there, so opening the chat lands on it.
                let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: accountPeerId))
                |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                    guard let self, let peer, let navigationController = self.effectiveNavigationController else {
                        return
                    }
                    self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer), keepStack: .always, purposefulAction: {}, peekData: nil, forceOpenChat: true))
                })
                return true
            }), in: .current)
        })
    }
}
