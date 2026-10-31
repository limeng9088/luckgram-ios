import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore
import ContextUI
import TelegramPresentationData
import StorageUsageScreen
import SettingsUI

// Luckgram 08 (cache): "…" menu entry that opens the chat's storage page, where its keep-media
// period can be set (overriding the private chats / groups / channels setting).
extension PeerInfoScreenNode {
    func luckgramChatStorageMenuItem(peer: EnginePeer) -> ContextMenuItem? {
        if peer.id == self.context.account.peerId {
            return nil
        }
        return .action(ContextMenuActionItem(text: LuckgramCacheStrings.profileMenuStorage(self.presentationData.strings), icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Timer"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.dismissWithoutContent)
            self?.openLuckgramChatStorage(peer: peer)
        }))
    }
    
    func openLuckgramChatStorage(peer: EnginePeer) {
        guard let controller = self.controller else {
            return
        }
        let context = self.context
        let storageController = StorageUsageScreen(context: context, makeStorageUsageExceptionsScreen: { category in
            return storageUsageExceptionsScreen(context: context, category: category)
        }, peer: peer)
        controller.push(storageController)
    }
}
