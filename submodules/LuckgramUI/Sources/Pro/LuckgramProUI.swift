import Foundation
import UIKit
import Display
import AccountContext

/// specs#87 (29): the numbers for the perk texts (remote config, then the Pro state), the live
/// perk rows, their icons, and the one "upgrade to Pro" sheet (需求 6).
public enum LuckgramProUI {
    public static func numbers() -> LuckgramProPerks.Numbers {
        let config = LuckgramSettings.shared
        let s = LuckgramPro.shared.state
        let now = Date()
        var n = LuckgramProPerks.Numbers()
        n.accountsMaxPro = config.remoteInt(LuckgramProPerks.cfgAccountsMaxPro, default: LuckgramProState.accountsMaxPro)
        n.chatPro = config.remoteInt(LuckgramProPerks.cfgChatPro, default: 0)
        n.chatFree = config.remoteInt(LuckgramProPerks.cfgChatFree, default: 0)
        n.monthlyCredits = config.remoteInt(LuckgramProPerks.cfgMonthlyCredits, default: s.creditsTotal > 0 ? s.creditsTotal : LuckgramProPerks.defaultMonthlyCredits)
        n.summaryMaxPro = config.remoteInt(LuckgramProPerks.cfgSummaryMax, default: s.isPro(now: now) ? s.summaryMaxMessages(now: now) : LuckgramProState.summaryMaxPro)
        n.translatePro = config.remoteInt(LuckgramProPerks.cfgTranslatePro, default: 0)
        n.translateFree = config.remoteInt(LuckgramProPerks.cfgTranslateFree, default: 0)
        return n
    }

    /// The rows that are live now (empty when neither /v1/me nor the config lists any perk).
    public static func liveRows() -> [LuckgramProPerks.Row] {
        let perks = LuckgramProPerks.livePerks(fromMe: LuckgramPro.shared.state.perks, fromConfig: LuckgramSettings.shared.remoteConfig.string(LuckgramProPerks.cfgPerks, default: nil))
        return LuckgramProPerks.rows(perks: perks, numbers: numbers(), zh: LuckgramStrings.isChinese)
    }

    /// "本月 AI 点数 …" value for a Pro user, nil for free users.
    public static func creditsValue() -> String? {
        let s = LuckgramPro.shared.state
        guard s.isPro(now: Date()) else {
            return nil
        }
        let total = s.creditsTotal > 0 ? s.creditsTotal : numbers().monthlyCredits
        return LuckgramProPerks.Texts(zh: LuckgramStrings.isChinese).creditsValue(remaining: s.creditsRemaining, total: total, resetsAt: s.creditsResetsAt)
    }

    private static let glyphs: [String: (String, UInt32)] = [
        "agent_market": ("✦", 0x5E5CE6),
        "accounts": ("👥", 0x0A84FF),
        "ai": ("⚡", 0xFF9F0A),
        "summary": ("☰", 0x30B0C7),
        "translate": ("⇄", 0x34C759),
        "community": ("★", 0xFF375F),
        "no_ads": ("⊘", 0x8E8E93)
    ]

    /// A rounded colored square with a white glyph (drawn in code, no assets).
    public static func icon(_ perk: String, size: CGFloat = 30.0) -> UIImage? {
        let (glyph, rgb) = glyphs[perk] ?? ("✦", 0x5E5CE6)
        return generateImage(CGSize(width: size, height: size), rotatedContext: { s, ctx in
            ctx.clear(CGRect(origin: .zero, size: s))
            ctx.setFillColor(UIColor(rgb: rgb).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: CGRect(origin: .zero, size: s), cornerRadius: s.width * 0.28).cgPath)
            ctx.fillPath()
            UIGraphicsPushContext(ctx)
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: s.width * 0.52, weight: .semibold), .foregroundColor: UIColor.white]
            let text = glyph as NSString
            let ts = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (s.width - ts.width) / 2.0, y: (s.height - ts.height) / 2.0), withAttributes: attrs)
            UIGraphicsPopContext()
        })
    }

    /// The upgrade sheet: one line saying why + "See Pro" → the subscription page.
    public static func presentUpgrade(context: AccountContext, reason: LuckgramProPerks.Reason, from controller: ViewController?) {
        guard let controller else {
            return
        }
        let t = LuckgramProPerks.Texts(zh: LuckgramStrings.isChinese)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let sheet = ActionSheetController(presentationData: presentationData)
        weak var navigation = controller.navigationController as? NavigationController
        sheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: "**" + t.upgradeTitle + "**\n" + t.upgradeReason(reason), parseMarkdown: true),
                ActionSheetButtonItem(title: t.upgradeButton, color: .accent, font: .bold, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    navigation?.pushViewController(luckgramProController(context: context))
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                })
            ])
        ])
        controller.present(sheet, in: .window(.root))
    }

    /// `quota_exceeded` / `not_pro` → the upgrade sheet; true if it was shown.
    @discardableResult
    public static func handle(errorCode: String?, context: AccountContext, from controller: ViewController?) -> Bool {
        switch errorCode {
        case LuckgramProPerks.errorQuotaExceeded?:
            presentUpgrade(context: context, reason: .quota, from: controller)
            return true
        case LuckgramProPerks.errorNotPro?:
            LuckgramPro.shared.refresh()
            presentUpgrade(context: context, reason: .proOnly, from: controller)
            return true
        default:
            return false
        }
    }
}
