import Foundation
import UIKit
import Display
import AccountContext

/// specs#87 (29) 需求 3: "Premium model · 1 credit per message" in the AI assistant (18) and agent
/// chats (22/30), added through the assistant's quick button extension point. The choice is a
/// conversation property (`LuckgramAIConversation.modelTier`); free users get the upgrade sheet and
/// `credits_exhausted` switches back to the standard model with a message. The assistant is a native
/// full-screen modal, so native alerts are used here (Telegram ones would open behind it).
enum LuckgramProModelChoice {
    static func register() {
        LuckgramAIRegistry.registerQuickAction(.init(id: "model", title: ("模型", "Model"), icon: "sparkles") { host in
            show(host)
        })
    }

    private static func show(_ host: LuckgramAIChatHost) {
        let t = LuckgramProPerks.Texts(zh: LuckgramStrings.isChinese)
        let conversation = host.conversation
        let premium = conversation.modelTier == LuckgramProPerks.modelTierPremium
        let sheet = UIAlertController(title: t.modelTitle, message: LuckgramProUI.creditsValue().map { t.creditsTitle + " " + $0 }, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: (premium ? "" : "✓ ") + t.modelStandard, style: .default) { _ in
            conversation.modelTier = nil
        })
        sheet.addAction(UIAlertAction(title: (premium ? "✓ " : "") + t.modelPremium, style: .default) { [weak host] _ in
            guard let host else {
                return
            }
            if !LuckgramPro.shared.isPro {
                conversation.modelTier = nil
                presentUpgradeNative(host: host, reason: .premiumModel)
            } else if LuckgramPro.shared.credits <= 0 {
                conversation.modelTier = nil
                LuckgramPro.shared.refresh() // maybe a new period started
                alert(host, t.creditsExhausted)
            } else {
                conversation.modelTier = LuckgramProPerks.modelTierPremium
            }
        })
        sheet.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let view = host.viewController.view!
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1.0, height: 1.0)
        }
        host.viewController.present(sheet, animated: true)
    }

    /// A premium reply cost a credit: re-read the count.
    static func onPremiumReply() {
        LuckgramPro.shared.refresh()
    }

    /// `not_pro` / `quota_exceeded` → upgrade sheet; `credits_exhausted` → back to standard.
    static func onError(host: LuckgramAIChatHost, code: String?) {
        switch code {
        case LuckgramProPerks.errorCreditsExhausted?:
            host.conversation.modelTier = nil
            LuckgramPro.shared.refresh()
            alert(host, LuckgramProPerks.Texts(zh: LuckgramStrings.isChinese).creditsExhausted)
        case LuckgramProPerks.errorNotPro?:
            // the premium model, or something else Pro-only (e.g. a Pro market agent, 30)
            let premium = host.conversation.modelTier != nil
            host.conversation.modelTier = nil
            LuckgramPro.shared.refresh()
            presentUpgradeNative(host: host, reason: premium ? .premiumModel : .proOnly)
        case LuckgramProPerks.errorQuotaExceeded?:
            presentUpgradeNative(host: host, reason: .quota)
        default:
            break
        }
    }

    private static func alert(_ host: LuckgramAIChatHost, _ text: String) {
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        host.viewController.present(a, animated: true)
    }

    /// The upgrade sheet over the native assistant; "See Pro" closes the assistant and opens the Pro page.
    static func presentUpgradeNative(host: LuckgramAIChatHost, reason: LuckgramProPerks.Reason) {
        let t = LuckgramProPerks.Texts(zh: LuckgramStrings.isChinese)
        let context = host.context
        let sheet = UIAlertController(title: t.upgradeTitle, message: t.upgradeReason(reason), preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: t.upgradeButton, style: .default) { [weak host] _ in
            let modal: UIViewController? = host?.viewController.navigationController ?? host?.viewController
            modal?.dismiss(animated: true, completion: {
                (context.sharedContext.mainWindow?.viewController as? NavigationController)?.pushViewController(luckgramProController(context: context))
            })
        })
        sheet.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let view = host.viewController.view!
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1.0, height: 1.0)
        }
        host.viewController.present(sheet, animated: true)
    }
}
