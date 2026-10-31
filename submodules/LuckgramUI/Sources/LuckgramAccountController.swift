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

    var section: ItemListSectionId {
        switch self {
        case let .header(s, _), let .value(s, _, _, _, _), let .action(s, _, _, _), let .plan(s, _, _, _), let .footer(s, _, _):
            return s
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(s, _):
            return s * 1000
        case let .value(s, id, _, _, _), let .action(s, id, _, _), let .plan(s, id, _, _):
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
                        luckgramToast(context, tx.unlinkedNow, present: presentImpl)
                        load()
                    }, error: { error in
                        state.busy = false
                        luckgramToast(context, tx.error(error.code), present: presentImpl)
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

private final class LuckgramProState {
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
    let state = LuckgramProState()
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

    let entries = updated.get() |> map { _ -> [LuckgramAccountEntry] in
        var e: [LuckgramAccountEntry] = [.header(0, tx.proTitle)]
        guard let b = state.billing else {
            e.append(.value(0, 1, tx.proTitle, "—", state.loading))
            return e
        }
        e.append(.value(0, 1, tx.proTitle, b.pro ? tx.proUntil(LuckgramAccountLogic.date(b.proExpiresAt)) : tx.free, false))
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
    }
    return controller
}
