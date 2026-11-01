import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext
import LuckgramUI
import ChatControllerInteraction

/// Luckgram: chat summary (feature 19) — the "N 条未读消息 · 总结" bar and the summary card.
extension ChatControllerImpl {
    /// The model for this chat, created on first use; nil when the feature is off or not applicable.
    func luckgramSummaryModel() -> LuckgramChatSummaryModel? {
        if let current = self.chatDisplayNode.luckgramSummary {
            return current
        }
        guard LuckgramChatSummaryModel.isEnabled, let peerId = self.chatLocation.peerId, peerId.namespace != Namespaces.Peer.SecretChat else {
            return nil
        }
        if case .standard(.default) = self.presentationInterfaceState.mode {
        } else {
            return nil
        }
        let model = LuckgramChatSummaryModel(context: self.context, peerId: peerId, threadId: self.chatLocation.threadId)
        model.onChanged = { [weak self] in
            self?.chatDisplayNode.requestLayout(.animated(duration: 0.25, curve: .easeInOut))
        }
        model.jumpToMessage = { [weak self] id in
            self?.navigateToMessage(messageLocation: .id(id, NavigateToMessageParams(timestamp: nil, quote: nil)), animated: true)
        }
        model.presentController = { [weak self] c in
            self?.present(c, in: .window(.root))
        }
        self.chatDisplayNode.luckgramSummary = model
        return model
    }

    /// Called when the chat appears: shows the bar if there are many unread messages.
    func luckgramCheckSummaryBar() {
        guard LuckgramChatSummaryModel.isEnabled, self.chatLocation.threadId == nil, let peerId = self.chatLocation.peerId, peerId.namespace != Namespaces.Peer.SecretChat else {
            return
        }
        let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.PeerUnreadCount(id: peerId))
        |> deliverOnMainQueue).startStandalone(next: { [weak self] count in
            guard let self else {
                return
            }
            if count >= LuckgramChatSummaryModel.barMinUnread || self.chatDisplayNode.luckgramSummary != nil {
                self.luckgramSummaryModel()?.setUnread(count)
            }
        })
    }

    /// "总结聊天" in the chat menu.
    func luckgramShowSummaryRangePicker() {
        guard let model = self.luckgramSummaryModel() else {
            return
        }
        let sheet = model.makeRangePicker()
        sheet.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1.0, height: 1.0)
        }
        self.view.window?.rootViewController?.present(sheet, animated: true)
    }
}
