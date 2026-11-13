import Foundation
import UIKit
import Display
import ChatPresentationInterfaceState
import AttachmentUI
import LuckgramUI

extension ChatControllerImpl {
    /// Luckgram specs#94: a cell of the 「+」 panel was tapped.
    func luckgramPerformPlusAction(_ action: LuckgramPlusAction, dimmed: Bool) {
        switch action {
        case .gallery:
            self.luckgramOpenAttachmentTab(.gallery)
        case .camera:
            if dimmed {
                // no right to send photos/videos here: the gallery tab shows Telegram's own notice
                self.luckgramOpenAttachmentTab(.gallery)
            } else {
                self.luckgramClosePlusPanel()
                self.openCamera()
            }
        case .file:
            self.luckgramOpenAttachmentTab(.file)
        case .location:
            self.luckgramOpenAttachmentTab(.location)
        case .contact:
            self.luckgramOpenAttachmentTab(.contact)
        case .poll:
            self.luckgramOpenAttachmentTab(.poll)
        case .emoji, .quickReplies, .dictation, .aiWriting, .translate:
            self.chatDisplayNode.textInputPanelNode?.luckgramPerformPlusAction(action)
        }
    }

    private func luckgramOpenAttachmentTab(_ button: AttachmentButtonType) {
        if self.presentationInterfaceState.interfaceState.editMessage == nil, let _ = self.presentationInterfaceState.slowmodeState, self.presentationInterfaceState.subject != .scheduledMessages {
            if let rect = self.chatDisplayNode.frameForAttachmentButton() {
                self.interfaceInteraction?.displaySlowmodeTooltip(self.chatDisplayNode.view, rect)
            }
            return
        }
        self.luckgramClosePlusPanel()
        self.presentAttachmentMenu(subject: .luckgramTab(button))
    }

    private func luckgramClosePlusPanel() {
        guard case .luckgramPlus = self.presentationInterfaceState.inputMode else {
            return
        }
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
            return state.updatedInputMode({ _ in .none })
        })
    }
}
