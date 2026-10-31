// Luckgram — profile details (spec 07): ID and approximate registration date rows.
// Licensed under GNU GPL v. 2 or later.

import Foundation
import UIKit
import Display
import AccountContext
import TelegramPresentationData
import TelegramCore
import AsyncDisplayKit
import ContextUI
import UndoUI
import LuckgramProfileInfo

private func luckgramPeerType(_ peer: EnginePeer) -> LuckgramProfileInfoLogic.PeerType? {
    switch peer {
    case .user:
        return .user
    case .legacyGroup:
        return .legacyGroup
    case .channel:
        return .channel
    default:
        return nil
    }
}

private func luckgramCopy(_ text: String, toast: String, presentationData: PresentationData, controller: ViewController?) {
    UIPasteboard.general.string = text
    controller?.present(UndoOverlayController(presentationData: presentationData, content: .copy(text: toast), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
}

/// Whether profile_details rows apply to this profile (not topics, not the own settings page).
func luckgramProfileDetailsAvailable(data: PeerInfoScreenData) -> Bool {
    return LuckgramProfileInfo.isEnabled && data.threadData == nil
}

/// The "ID" row and, for users, the "Registered" row.
func luckgramProfileDetailsItems(peer: EnginePeer, presentationData: PresentationData, interaction: PeerInfoInteraction) -> [PeerInfoScreenItem] {
    guard let type = luckgramPeerType(peer) else {
        return []
    }
    let rawId = peer.id.id._internalGetInt64Value()
    let displayId = LuckgramProfileInfoLogic.displayId(type, id: rawId)
    let link = LuckgramProfileInfoLogic.userLink(type, id: rawId)

    var items: [PeerInfoScreenItem] = []
    items.append(PeerInfoScreenLabeledValueItem(id: AnyHashable("luckgram_peer_id"), label: LuckgramProfileInfo.idTitle, text: displayId, textColor: .primary, action: { _, _ in
        luckgramCopy(displayId, toast: LuckgramProfileInfo.idCopied, presentationData: presentationData, controller: interaction.getController())
    }, contextAction: { node, gesture, _ in
        guard let sourceNode = node as? ContextExtractedContentContainingNode, let controller = interaction.getController() else {
            return
        }
        var menu: [ContextMenuItem] = []
        menu.append(.action(ContextMenuActionItem(text: LuckgramProfileInfo.copyId, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor) }, action: { [weak controller] c, _ in
            c?.dismiss {
                luckgramCopy(displayId, toast: LuckgramProfileInfo.idCopied, presentationData: presentationData, controller: controller)
            }
        })))
        if let link {
            menu.append(.action(ContextMenuActionItem(text: LuckgramProfileInfo.copyLink, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Link"), color: theme.contextMenu.primaryColor) }, action: { [weak controller] c, _ in
                c?.dismiss {
                    luckgramCopy(link, toast: LuckgramProfileInfo.linkCopied, presentationData: presentationData, controller: controller)
                }
            })))
        }
        let contextController = makeContextController(presentationData: presentationData, source: .extracted(PeerInfoContextExtractedContentSource(sourceNode: sourceNode)), items: .single(ContextController.Items(content: .list(menu))), gesture: gesture)
        controller.present(contextController, in: .window(.root))
    }, requestLayout: { animated in
        interaction.requestLayout(animated)
    }))

    if case let .user(user) = peer, user.botInfo == nil, let registered = LuckgramProfileInfo.registrationText(userId: rawId) {
        items.append(PeerInfoScreenLabeledValueItem(id: AnyHashable("luckgram_registered"), label: LuckgramProfileInfo.registeredTitle, rightLabel: LuckgramProfileInfo.registeredInfo, text: registered, textColor: .primary, action: nil, requestLayout: { animated in
            interaction.requestLayout(animated)
        }))
    }
    return items
}
