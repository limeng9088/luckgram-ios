import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import UndoUI

/// specs#89 (31): 「加入 Pro 社群」. Pro users get a one-time invite link from S14 and it opens inside
/// the app (Telegram's own join sheet); members are told so and taken to the group; free users and
/// `not_pro` get the upgrade prompt.
public enum LuckgramProCommunity {
    public static let texts = LuckgramProCommunityLogic.Texts(zh: LuckgramStrings.isChinese)

    private static let channelKey = "_pro_community_channel"
    private static let request = MetaDisposable()
    private static var inFlight = false

    /// Whether the 「加入 Pro 社群」 row is shown at all.
    public static var showRow: Bool {
        return LuckgramProCommunityLogic.showRow(featureEnabled: LuckgramSettings.shared.isEnabled(LuckgramProCommunityLogic.featureKey),
                                                 hasPerk: LuckgramPro.shared.hasPerk(LuckgramProState.perkCommunity))
    }

    /// The row was tapped (main queue). `upgrade` shows the upgrade prompt (29) for free users.
    public static func join(context: AccountContext, navigationController: @escaping () -> NavigationController?, present: @escaping (ViewController) -> Void, upgrade: @escaping () -> Void) {
        if inFlight {
            return
        }
        if !LuckgramPro.shared.isPro {
            upgrade()
            return
        }
        inFlight = true
        request.set((LuckgramAI.shared.requestJSON(method: "POST", path: LuckgramProCommunityLogic.invitePath, body: [:])
        |> deliverOnMainQueue).start(next: { body in
            inFlight = false
            switch LuckgramProCommunityLogic.parse(body) {
            case let .join(link):
                openLink(context: context, link, navigationController())
            case let .alreadyMember(channelId, link):
                openGroup(context: context, channelId: channelId, link: link, navigationController: navigationController, present: present)
            case .badAnswer:
                toast(context, LuckgramAIError(code: LuckgramAIError.upstreamUnavailable).localizedMessage, present)
            }
        }, error: { error in
            inFlight = false
            if error.code == LuckgramProCommunityLogic.codeNotPro {
                LuckgramPro.shared.refresh()
                upgrade()
            } else if error.code == LuckgramProCommunityLogic.codeAlreadyMember {
                openGroup(context: context, channelId: 0, link: nil, navigationController: navigationController, present: present)
            } else if error.code != LuckgramAIError.cancelled {
                toast(context, error.localizedMessage, present)
            }
        }))
    }

    /// 「你已经在 Pro 社群里」, then the group itself when we know which it is.
    private static func openGroup(context: AccountContext, channelId: Int64, link: String?, navigationController: @escaping () -> NavigationController?, present: @escaping (ViewController) -> Void) {
        var channelId = channelId
        if channelId > 0 {
            LuckgramSettings.shared.setString(channelKey, String(channelId))
        } else {
            channelId = Int64(LuckgramSettings.shared.string(channelKey, default: nil) ?? "") ?? 0
        }
        toast(context, texts.alreadyMember, present)
        guard channelId > 0 else {
            if let link {
                openLink(context: context, link, navigationController())
            }
            return
        }
        let peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(channelId))
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).start(next: { peer in
            if let peer, let nav = navigationController() {
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: nav, context: context, chatLocation: .peer(peer)))
            } else if let link {
                openLink(context: context, link, navigationController())
            }
        })
    }

    private static func openLink(context: AccountContext, _ url: String, _ navigationController: NavigationController?) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: navigationController, dismissInput: {})
    }

    private static func toast(_ context: AccountContext, _ text: String, _ present: (ViewController) -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }
}
