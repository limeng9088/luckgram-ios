import Foundation
import UIKit
import Photos
import Display
import TelegramCore
import MediaPickerUI
import LuckgramRoundVideo

// Luckgram: send a gallery video as a round video message (spec 03-round-video).
extension ChatControllerImpl {
    func luckgramSetupRoundVideo(controller: MediaPickerScreenImpl, isEditingMessage: Bool, isScheduledMessages: Bool, bannedSendVideos: (Int32, Bool)?) {
        guard LuckgramRoundVideo.isEnabled, !isEditingMessage, !isScheduledMessages, bannedSendVideos == nil else {
            return
        }
        if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.hasBannedPermission(.banSendInstantVideos) != nil {
            return
        }
        if let group = self.presentationInterfaceState.renderedPeer?.peer as? TelegramGroup, group.hasBannedPermission(.banSendInstantVideos) {
            return
        }
        let title = LuckgramRoundVideo.string(.sendAsRound, self.presentationData.strings)
        controller.luckgramSendAsRoundVideo = (title, { [weak self] asset in
            self?.luckgramPresentRoundVideoScreen(asset: asset)
        })
    }

    func luckgramPresentRoundVideoScreen(asset: PHAsset) {
        let screen = LuckgramRoundVideoScreen(context: self.context, asset: asset, completion: { [weak self] message in
            guard let self else {
                return
            }
            let replyMessageSubject = self.presentationInterfaceState.interfaceState.replyMessageSubject
            let updatedMessage = message.withUpdatedReplyToMessageId(replyMessageSubject?.subjectModel)

            self.chatDisplayNode.setupSendActionOnViewUpdate({ [weak self] in
                guard let self else {
                    return
                }
                self.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                    $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil) }
                })
            }, nil)

            let transformedMessages = self.transformEnqueueMessages([updatedMessage], silentPosting: self.presentationInterfaceState.interfaceState.silentPosting)
            self.sendMessages(transformedMessages)
        })
        self.push(screen)
    }
}
