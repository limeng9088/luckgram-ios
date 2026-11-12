import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

// Luckgram Features → Account (S6, luckgram-specs#31) and → Luckgram Pro (S7, #32).
// Same pages, texts and flow as LuckgramAccountActivity / LuckgramProActivity on Android.

private final class LuckgramAccountArguments {
    let action: (Int) -> Void

    init(action: @escaping (Int) -> Void) {
        self.action = action
    }
}

private enum LuckgramAccountEntry: ItemListNodeEntry {
    case header(Int32, String)
    case value(Int32, Int32, String, String, Bool) // section, id, title, label, loading
    case action(Int32, Int32, String, ItemListActionKind)
    case plan(Int32, Int32, String, String)
    case footer(Int32, Int32, String)
    case perk(Int32, Int32, String, String, String?, String) // section, id, perk, title, badge, text (29)

    var section: ItemListSectionId {
        switch self {
        case let .header(s, _), let .value(s, _, _, _, _), let .action(s, _, _, _), let .plan(s, _, _, _), let .footer(s, _, _), let .perk(s, _, _, _, _, _):
            return s
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(s, _):
            return s * 1000
        case let .value(s, id, _, _, _), let .action(s, id, _, _), let .plan(s, id, _, _), let .perk(s, id, _, _, _, _):
            return s * 1000 + id
        case let .footer(s, id, _):
            return s * 1000 + 900 + id
        }
    }

    static func ==(lhs: LuckgramAccountEntry, rhs: LuckgramAccountEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a1, a2), .header(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.value(a1, a2, a3, a4, a5), .value(b1, b2, b3, b4, b5)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5
        case let (.action(a1, a2, a3, a4), .action(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.plan(a1, a2, a3, a4), .plan(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.footer(a1, a2, a3), .footer(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.perk(a1, a2, a3, a4, a5, a6), .perk(b1, b2, b3, b4, b5, b6)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5 && a6 == b6
        default:
            return false
        }
    }

    static func <(lhs: LuckgramAccountEntry, rhs: LuckgramAccountEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramAccountArguments
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text.uppercased(), sectionId: self.section)
        case let .value(_, _, title, label, loading):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, enabled: !loading, label: loading ? "…" : label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .action(_, id, title, kind):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: kind, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.action(Int(id))
            })
        case let .plan(_, id, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.action(Int(id))
            })
        case let .footer(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .perk(_, _, perk, title, badge, text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: LuckgramProUI.icon(perk), title: title, titleBadge: badge, label: text, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        }
    }
}

private func luckgramToast(_ context: AccountContext, _ text: String, present: ((ViewController) -> Void)?) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
}

private func luckgramOpenTelegramLink(_ context: AccountContext, _ url: String, _ controller: ViewController?) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: controller?.navigationController as? NavigationController, dismissInput: {})
}

private func luckgramItemListController(context: AccountContext, title: String, entries: Signal<[LuckgramAccountEntry], NoError>, arguments: LuckgramAccountArguments) -> ItemListController {
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, entries)
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}

// MARK: - Account (S6)

private final class LuckgramAccountState {
    var status: LuckgramAccountLogic.LinkStatus?
    var loading = true
    var busy = false
    var pendingNonce: String?
    var expiresAt = Date()
}

/// Luckgram Features → Account. Linking: `POST /v1/link/start` → open `t.me/<bot>?start=<nonce>`
/// (inside this app: the bot chat opens, the user taps Start) → poll `GET /v1/link?nonce=` every
/// 2 s while the page exists, until the request is no longer pending or the nonce expires.
public func luckgramAccountController(context: AccountContext) -> ViewController {
    let tx = LuckgramAccountLogic.Texts(zh: LuckgramStrings.isChinese)
    let state = LuckgramAccountState()
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    let refresh = {
        version += 1
        updated.set(version)
    }
    let requests = DisposableSet()
    let pollTimer = MetaDisposable()
    weak var controllerRef: ViewController?
    var presentImpl: ((ViewController) -> Void)?

    func load() {
        requests.add((LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/link")).start(next: { j in
            state.status = LuckgramAccountLogic.parseLink(j)
            state.loading = false
            refresh()
        }, error: { error in
            state.loading = false
            refresh()
            if error.code != LuckgramAIError.cancelled {
                luckgramToast(context, tx.error(error.code), present: presentImpl)
            }
        }))
    }

    func finish(_ request: String?) {
        state.pendingNonce = nil
        pollTimer.set(nil)
        luckgramToast(context, request == "linked" ? tx.linkedNow : tx.linkResult(request, max: state.status?.maxDevices ?? 0), present: presentImpl)
        load()
    }

    func schedulePoll() {
        pollTimer.set((Signal<Void, NoError>.single(Void()) |> delay(LuckgramAccountLogic.pollInterval, queue: .mainQueue())).start(next: {
            // The page was closed (controller released): stop polling.
            guard controllerRef != nil, let nonce = state.pendingNonce else {
                return
            }
            if !LuckgramAccountLogic.shouldPoll(request: nil, now: Date(), expiresAt: state.expiresAt) {
                finish("expired")
                return
            }
            requests.add(LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/link?nonce=\(nonce)").start(next: { j in
                let s = LuckgramAccountLogic.parseLink(j)
                state.status = s
                if LuckgramAccountLogic.shouldPoll(request: s.request, now: Date(), expiresAt: state.expiresAt) {
                    schedulePoll()
                } else {
                    finish(s.request)
                }
            }, error: { _ in
                schedulePoll() // offline for a moment: keep trying until the nonce expires
            }))
        }))
    }

    let arguments = LuckgramAccountArguments(action: { id in
        if state.busy {
            return
        }
        switch id {
        case 2 where state.pendingNonce == nil:
            state.busy = true
            requests.add(LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/link/start").start(next: { j in
                state.busy = false
                let st = LuckgramAccountLogic.parseStart(j)
                guard LuckgramAccountLogic.isTelegramLink(st.url), !st.nonce.isEmpty else {
                    luckgramToast(context, tx.error(nil), present: presentImpl)
                    return
                }
                state.pendingNonce = st.nonce
                state.expiresAt = st.expiresAt ?? Date().addingTimeInterval(600)
                refresh()
                luckgramOpenTelegramLink(context, st.url, controllerRef)
                schedulePoll()
            }, error: { error in
                state.busy = false
                luckgramToast(context, tx.error(error.code), present: presentImpl)
                if error.code == "already_linked" {
                    load()
                }
            }))
        case 3:
            presentImpl?(textAlertController(context: context, title: tx.unlinkConfirmTitle, text: tx.unlinkConfirmText, actions: [
                TextAlertAction(type: .genericAction, title: LuckgramStrings.cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: tx.unlink, action: {
                    state.busy = true
                    requests.add(LuckgramAI.shared.requestJSON(method: "DELETE", path: "/v1/link").start(next: { _ in
                        state.busy = false
                        LuckgramNearby.onUnlinked() // 25: the server deleted the nearby card
                        LuckgramSquare.clearCache() // 26: link state / profile belong to the linked user
                        luckgramToast(context, tx.unlinkedNow, present: presentImpl)
                        load()
                    }, error: { error in
                        state.busy = false
                        luckgramToast(context, tx.error(error.code), present: presentImpl)
                    }))
                })
            ]))
        case 4:
            // 26 Square (spec item 8): one tap deletes all of this user's posts, comments and likes.
            let sq = LuckgramSquare.texts
            presentImpl?(textAlertController(context: context, title: sq.deleteMyData, text: sq.deleteMyDataConfirm, actions: [
                TextAlertAction(type: .genericAction, title: LuckgramStrings.cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: sq.delete, action: {
                    state.busy = true
                    refresh()
                    requests.add(LuckgramAI.shared.requestJSON(method: "DELETE", path: "/v1/square/me").start(next: { _ in
                        state.busy = false
                        LuckgramSquare.clearCache()
                        LuckgramSquare.noteNeedsRefresh()
                        refresh()
                        luckgramToast(context, sq.deletedMyData, present: presentImpl)
                    }, error: { error in
                        state.busy = false
                        refresh()
                        luckgramToast(context, LuckgramSquare.errorText(error), present: presentImpl)
                    }))
                })
            ]))
        default:
            break
        }
    })

    let entries = updated.get() |> map { _ -> [LuckgramAccountEntry] in
        var e: [LuckgramAccountEntry] = [.header(0, tx.telegramAccount)]
        let linked = state.status?.linked ?? false
        e.append(.value(0, 1, tx.telegramAccount, linked ? tx.linked : tx.notLinked, state.loading && state.status == nil))
        if state.status != nil {
            if state.pendingNonce != nil {
                e.append(.value(0, 2, tx.waiting, "", true))
            } else if linked {
                e.append(.action(0, 3, tx.unlink, .destructive))
            } else {
                e.append(.action(0, 2, tx.link, .generic))
            }
        }
        var info = tx.linkInfo
        if let s = state.status, s.linked, s.maxDevices > 0 {
            info = tx.devices(s.devices, s.maxDevices) + "\n\n" + info
        }
        e.append(.footer(0, 0, info))
        if linked && LuckgramSquare.isFeatureEnabled {
            // 26 Square: delete everything this user posted (spec 26 item 8).
            let sq = LuckgramSquare.texts
            e.append(.header(1, sq.title))
            e.append(.action(1, 4, sq.deleteMyData, .destructive))
            e.append(.footer(1, 1, sq.deleteMyDataConfirm))
        }
        return e
    }

    let controller = luckgramItemListController(context: context, title: tx.accountTitle, entries: entries, arguments: arguments)
    controllerRef = controller
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    controller.didAppear = { _ in
        if state.pendingNonce == nil && !state.busy {
            load()
        }
    }
    load()
    return controller
}

// MARK: - Luckgram Pro (S7)

private final class LuckgramProPageState {
    var billing: LuckgramAccountLogic.Billing?
    var loading = true
    var busy = false
    var expiresBefore: String?
    var refreshesLeft = 0
}

/// Luckgram Features → Luckgram Pro. Buying: `POST /v1/billing/checkout` → open the Stars invoice
/// (the payment form opens inside this app) → the bot credits the payment; this page re-reads
/// `GET /v1/billing/plans` when it reappears and a few more times until the end date moves.
public func luckgramProController(context: AccountContext) -> ViewController {
    let tx = LuckgramAccountLogic.Texts(zh: LuckgramStrings.isChinese)
    let state = LuckgramProPageState()
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    let refresh = {
        version += 1
        updated.set(version)
    }
    let requests = DisposableSet()
    let timer = MetaDisposable()
    weak var controllerRef: ViewController?
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?

    func load(_ then: (() -> Void)? = nil) {
        requests.add(LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/billing/plans").start(next: { j in
            state.billing = LuckgramAccountLogic.parseBilling(j)
            state.loading = false
            refresh()
            then?()
        }, error: { error in
            state.loading = false
            refresh()
            if error.code != LuckgramAIError.cancelled {
                luckgramToast(context, tx.error(error.code), present: presentImpl)
            }
        }))
    }

    func refreshAfterPurchase() {
        timer.set((Signal<Void, NoError>.single(Void()) |> delay(LuckgramAccountLogic.proRefreshInterval, queue: .mainQueue())).start(next: {
            if controllerRef == nil || state.refreshesLeft <= 0 {
                return
            }
            state.refreshesLeft -= 1
            load {
                if let now = state.billing?.proExpiresAt, now != state.expiresBefore {
                    state.refreshesLeft = 0
                    refresh()
                    LuckgramPro.shared.refresh() // 29: payment went through
                    luckgramToast(context, tx.proActive, present: presentImpl)
                } else if state.refreshesLeft > 0 {
                    refreshAfterPurchase()
                } else {
                    refresh()
                }
            }
        }))
    }

    let arguments = LuckgramAccountArguments(action: { id in
        if id == 50 {
            // Luckgram 32: cloud backup (Pro); free users get the upgrade prompt.
            if luckgramIsPro() {
                pushImpl?(luckgramCloudBackupController(context: context))
            } else {
                presentImpl?(luckgramProUpgradeController(context: context, reason: LuckgramCloudBackupStrings.proOnly, openPro: nil))
            }
            return
        }
        if id == 4 {
            // specs#89 (31): Pro community; free users get the same upgrade prompt as cloud backup (32).
            LuckgramProCommunity.join(context: context, navigationController: {
                return controllerRef?.navigationController as? NavigationController
            }, present: { c in
                presentImpl?(c)
            }, upgrade: {
                presentImpl?(luckgramProUpgradeController(context: context, reason: LuckgramProCommunity.texts.proOnly, openPro: nil))
            })
            return
        }
        guard !state.busy, let billing = state.billing else {
            return
        }
        if id == 2 {
            pushImpl?(luckgramAccountController(context: context))
            return
        }
        let index = id - 100
        guard index >= 0, index < billing.plans.count else {
            return
        }
        state.busy = true
        requests.add(LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/billing/checkout", body: ["plan": billing.plans[index].id]).start(next: { j in
            state.busy = false
            let url = j["url"] as? String ?? ""
            guard LuckgramAccountLogic.isTelegramLink(url) else {
                luckgramToast(context, tx.error(nil), present: presentImpl)
                return
            }
            state.expiresBefore = state.billing?.proExpiresAt
            state.refreshesLeft = LuckgramAccountLogic.proRefreshTimes
            refresh()
            luckgramOpenTelegramLink(context, url, controllerRef)
            refreshAfterPurchase()
        }, error: { error in
            state.busy = false
            luckgramToast(context, tx.error(error.code), present: presentImpl)
            if error.code == "not_linked" || error.code == "billing_disabled" {
                load()
            }
        }))
    })

    let perkTexts = LuckgramProPerks.Texts(zh: LuckgramStrings.isChinese)
    /// 29 需求 2: the live perks in their fixed order, in their own section at the bottom.
    func addPerks(_ e: inout [LuckgramAccountEntry]) {
        for (i, row) in LuckgramProUI.liveRows().enumerated() {
            e.append(.perk(3, Int32(10 + i), row.perk, row.title, row.proOnly ? perkTexts.proOnlyBadge : nil, row.subtitle))
        }
    }

    // Luckgram 32: "Cloud backup" section under the plans.
    func cloudBackupEntries(isPro: Bool) -> [LuckgramAccountEntry] {
        return [
            .header(1, LuckgramCloudBackupStrings.header),
            .plan(1, 50, LuckgramCloudBackupStrings.header, isPro ? "" : "Pro"),
            .footer(1, 0, LuckgramCloudBackupStrings.proOnly)
        ]
    }

    func billingEntries() -> [LuckgramAccountEntry] {
        var e: [LuckgramAccountEntry] = [.header(0, tx.proTitle)]
        guard let b = state.billing else {
            e.append(.value(0, 1, tx.proTitle, "—", state.loading))
            return e
        }
        e.append(.value(0, 1, tx.proTitle, b.pro ? tx.proUntil(LuckgramAccountLogic.date(b.proExpiresAt)) : tx.free, false))
        if let credits = LuckgramProUI.creditsValue() {
            e.append(.value(0, 4, perkTexts.creditsTitle, credits, false))
        }
        if !b.enabled {
            e.append(.footer(0, 0, tx.notOnSale))
            return e
        }
        if !b.linked {
            e.append(.action(0, 2, tx.goLink, .generic))
            e.append(.footer(0, 0, tx.linkFirst))
            return e
        }
        if state.refreshesLeft > 0 {
            e.append(.value(0, 3, tx.checking, "", true))
        }
        for (i, p) in b.plans.enumerated() {
            e.append(.plan(0, Int32(100 + i), tx.plan(p), tx.stars(p.stars)))
        }
        e.append(.footer(0, 0, tx.proInfo))
        return e
    }

    let entries = combineLatest(updated.get(), LuckgramPro.shared.stateSignal) |> map { _, pro -> [LuckgramAccountEntry] in
        var e = billingEntries() + cloudBackupEntries(isPro: pro.isPro(now: Date()))
        // specs#89 (31): Pro community, its own section below cloud backup; follows the Pro state (perks).
        if LuckgramProCommunity.showRow {
            e.append(.action(2, 4, LuckgramProCommunity.texts.join, .generic))
            e.append(.footer(2, 0, LuckgramProCommunity.texts.info))
        }
        addPerks(&e) // 29 需求 2: section 3, last
        return e
    }

    let controller = luckgramItemListController(context: context, title: tx.proTitle, entries: entries, arguments: arguments)
    controllerRef = controller
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    controller.didAppear = { _ in
        load()
        LuckgramPro.shared.refresh() // 29: same state everywhere
    }
    return controller
}
