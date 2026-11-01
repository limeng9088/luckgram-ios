import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI
import PromptUI
import UndoUI
import LuckgramDiscover

// People Nearby (spec 25, luckgram-specs#63). Same flow and texts as NearbyActivity on Android:
// S6 link + username check → intro (first time) → location permission → browse;
// "Visible nearby" uploads the card with a coarsened location. Location is read only when the
// page opens, on refresh and on renew.

private final class NearbyArguments {
    let action: (Int) -> Void
    let toggle: (Int, Bool) -> Void

    init(action: @escaping (Int) -> Void, toggle: @escaping (Int, Bool) -> Void) {
        self.action = action
        self.toggle = toggle
    }
}

private enum NearbyEntry: ItemListNodeEntry {
    case header(Int32, Int32, String)
    case action(Int32, Int32, String, ItemListActionKind, Bool)
    case toggle(Int32, Int32, String, Bool, Bool)
    case value(Int32, Int32, String, String, Bool)
    case footer(Int32, Int32, String)
    case person(Int32, Int32, String, String, UIImage?)

    var section: ItemListSectionId {
        switch self {
        case let .header(s, _, _), let .action(s, _, _, _, _), let .toggle(s, _, _, _, _), let .value(s, _, _, _, _), let .footer(s, _, _), let .person(s, _, _, _, _):
            return s
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(s, id, _):
            return s * 10000 + id
        case let .action(s, id, _, _, _), let .toggle(s, id, _, _, _), let .value(s, id, _, _, _), let .person(s, id, _, _, _):
            return s * 10000 + 100 + id
        case let .footer(s, id, _):
            return s * 10000 + 9000 + id
        }
    }

    static func ==(lhs: NearbyEntry, rhs: NearbyEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a1, a2, a3), .header(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.action(a1, a2, a3, a4, a5), .action(b1, b2, b3, b4, b5)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5
        case let (.toggle(a1, a2, a3, a4, a5), .toggle(b1, b2, b3, b4, b5)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5
        case let (.value(a1, a2, a3, a4, a5), .value(b1, b2, b3, b4, b5)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5
        case let (.footer(a1, a2, a3), .footer(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.person(a1, a2, a3, a4, a5), .person(b1, b2, b3, b4, b5)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 === b5
        default:
            return false
        }
    }

    static func <(lhs: NearbyEntry, rhs: NearbyEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! NearbyArguments
        switch self {
        case let .header(_, _, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text.uppercased(), sectionId: self.section)
        case let .action(_, id, title, kind, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? kind : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.action(Int(id))
            })
        case let .toggle(_, id, title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(Int(id), value)
            })
        case let .value(_, id, title, label, loading):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, enabled: !loading, label: loading ? "…" : label, sectionId: self.section, style: .blocks, disclosureStyle: loading ? .none : .arrow, action: loading ? nil : {
                arguments.action(Int(id))
            })
        case let .footer(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .person(_, id, name, bio, icon):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: name, label: bio, labelStyle: .detailText, sectionId: self.section, style: .blocks, action: {
                arguments.action(Int(id))
            })
        }
    }
}

private final class NearbyState {
    var linked: Bool?
    var username: String?
    var displayName = ""
    var avatarPath: String?
    var permissionDenied = false
    var locating = false
    var loadingList = false
    var busy = false
    var locationError: String?
    var people: [NearbyLogic.Person]?
    var coordinate: (lat: Double, lon: Double)?
    var avatars: [String: UIImage] = [:]
}

private let idGoLink = 1, idGoUsername = 2, idIntroOk = 3, idOpenSettings = 4, idRenew = 6, idBio = 7, idRefresh = 9, idBlocked = 10
private let idVisible = 5, idPhoto = 8
private let idPerson = 1000

private func nearbyAvatarImage(_ data: Data) -> UIImage? {
    guard let image = UIImage(data: data) else {
        return nil
    }
    let size = CGSize(width: 30, height: 30)
    return generateImage(size, rotatedContext: { size, context in
        context.clear(CGRect(origin: .zero, size: size))
        context.addEllipse(in: CGRect(origin: .zero, size: size))
        context.clip()
        if let cg = image.cgImage {
            context.draw(cg, in: CGRect(origin: .zero, size: size))
        }
    })
}

public func luckgramNearbyController(context: AccountContext) -> ViewController {
    let tx = NearbyLogic.Texts(zh: LuckgramStrings.isChinese)
    let state = NearbyState()
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    let refresh = {
        version += 1
        updated.set(version)
    }
    let requests = DisposableSet()
    let listRequest = MetaDisposable()
    var locator: LuckgramNearbyLocator?
    weak var controllerRef: ViewController?
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?

    func toast(_ text: String) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }

    func showError(_ error: LuckgramAIError) {
        if error.code == LuckgramAIError.cancelled {
            return
        }
        switch error.code {
        case LuckgramAIError.rateLimited:
            toast(tx.rateLimited(error.retryAfterSeconds))
        case "banned":
            toast(tx.banned)
        case "nearby_disabled":
            toast(tx.disabled)
        case "not_linked":
            toast(tx.notLinked)
        default:
            toast(error.localizedMessage)
        }
    }

    func precondition() -> NearbyLogic.Precondition {
        return NearbyLogic.precondition(linked: state.linked ?? false, username: state.username)
    }

    func openUrl(_ url: String) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: controllerRef?.navigationController as? NavigationController, dismissInput: {})
    }

    func loadList() {
        guard let c = state.coordinate else {
            return
        }
        state.loadingList = true
        refresh()
        listRequest.set(LuckgramAI.shared.requestJSON(method: "GET", path: NearbyLogic.queryPath(lat: c.lat, lon: c.lon)).start(next: { j in
            state.loadingList = false
            let people = NearbyLogic.parseList(j, selfUsername: state.username)
            state.people = people
            refresh()
            for p in people where state.avatars[p.id] == nil {
                guard let s = p.avatarUrl, let url = URL(string: s) else {
                    continue
                }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let image = nearbyAvatarImage(data) else {
                        return
                    }
                    Queue.mainQueue().async {
                        state.avatars[p.id] = image
                        refresh()
                    }
                }.resume()
            }
        }, error: { error in
            state.loadingList = false
            LuckgramNearby.onError(error)
            if error.code == "not_linked" {
                state.linked = false
            }
            showError(error)
            refresh()
        }))
    }

    func locate(_ then: @escaping () -> Void) {
        if state.locating {
            return
        }
        state.locating = true
        state.locationError = nil
        refresh()
        let l = LuckgramNearbyLocator()
        locator = l
        l.request { result in
            state.locating = false
            locator = nil
            switch result {
            case let .location(c):
                guard NearbyLogic.isValidLocation(lat: c.latitude, lon: c.longitude) else {
                    state.locationError = tx.locationFailed
                    refresh()
                    return
                }
                // Keep only the coarsened value in memory, too.
                state.coordinate = (NearbyLogic.coarsen(c.latitude), NearbyLogic.coarsen(c.longitude))
                state.permissionDenied = false
                refresh()
                then()
            case .denied:
                state.permissionDenied = true
                refresh()
            case .servicesOff:
                state.locationError = tx.locationOff
                refresh()
            case .failed:
                state.locationError = tx.locationFailed
                refresh()
            }
        }
    }

    func reload() {
        guard precondition() == .ready, LuckgramNearby.introDone else {
            return
        }
        locate {
            loadList()
        }
    }

    func syncMe() {
        requests.add(LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/nearby/me").start(next: { j in
            LuckgramNearby.apply(NearbyLogic.parseMe(j), accountId: nil)
            refresh()
        }, error: { error in
            LuckgramNearby.onError(error)
            refresh()
        }))
    }

    func loadAccount() {
        guard LuckgramNearby.isFeatureEnabled else {
            return
        }
        let peerSignal = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        requests.add((peerSignal |> deliverOnMainQueue).start(next: { peer in
            state.username = peer?.addressName
            if let peer {
                state.displayName = peer.compactDisplayTitle
                if let rep = peer.smallProfileImage {
                    state.avatarPath = context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(rep.resource.id))
                }
            }
            refresh()
        }))
        requests.add(LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/link").start(next: { j in
            let linked = j["linked"] as? Bool ?? false
            state.linked = linked
            if !linked {
                LuckgramNearby.onUnlinked()
            }
            refresh()
            // The username arrives on the same main-queue turn or earlier (local data).
            Queue.mainQueue().after(0.1) {
                if precondition() == .ready && LuckgramNearby.introDone && state.people == nil && !state.locating {
                    syncMe()
                    reload()
                }
            }
        }, error: { error in
            showError(error)
            refresh()
        }))
    }

    func avatarBase64() -> String? {
        guard let path = state.avatarPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty, data.count <= NearbyLogic.avatarMaxBytes * 3 / 4 else {
            return nil
        }
        // The server re-encodes and strips metadata; UIImage → JPEG here too, to send plain JPEG.
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85), jpeg.count <= NearbyLogic.avatarMaxBytes * 3 / 4 else {
            return nil
        }
        return jpeg.base64EncodedString()
    }

    func uploadCard() {
        guard let username = state.username, !username.isEmpty, let c = state.coordinate else {
            return
        }
        let wasVisible = LuckgramNearby.isVisible
        let body = NearbyLogic.cardBody(displayName: state.displayName, bio: LuckgramNearby.bio, username: username, lat: c.lat, lon: c.lon, avatarBase64: LuckgramNearby.showPhoto ? avatarBase64() : "")
        state.busy = true
        refresh()
        requests.add(LuckgramAI.shared.requestJSON(method: "PUT", path: "/v1/nearby/me", body: body).start(next: { j in
            state.busy = false
            var j = j
            if j["visible"] == nil {
                j["visible"] = true
            }
            let me = NearbyLogic.parseMe(j)
            LuckgramNearby.apply(me, accountId: context.account.id.int64)
            if !me.visible {
                // S10: a reported card awaiting review comes back as visible:false
                toast(tx.underReview)
            } else if wasVisible {
                toast(tx.renewed)
            }
            refresh()
            loadList()
        }, error: { error in
            state.busy = false
            LuckgramNearby.onError(error)
            if error.code == "not_linked" {
                state.linked = false
            }
            showError(error)
            refresh()
        }))
    }

    func setVisible(_ on: Bool) {
        if state.busy {
            return
        }
        if !on {
            state.busy = true
            refresh()
            requests.add(LuckgramNearby.turnOff().start(next: { _ in
                state.busy = false
                refresh()
            }, error: { error in
                state.busy = false
                showError(error)
                refresh()
            }))
            return
        }
        // Fresh fix for every upload (switch on / renew).
        locate {
            uploadCard()
        }
    }

    func showPerson(_ p: NearbyLogic.Person) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let text = (p.bio.isEmpty ? "" : p.bio + "\n\n") + "@\(p.username) · \(tx.bucket(p.bucket))"
        presentImpl?(textAlertController(context: context, title: p.displayName, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: tx.sendMessage, action: {
                openUrl("https://t.me/\(p.username)")
            }),
            TextAlertAction(type: .genericAction, title: tx.report, action: {
                var actions: [TextAlertAction] = NearbyLogic.reportReasons.map { reason in
                    TextAlertAction(type: .genericAction, title: tx.reportReason(reason), action: {
                        requests.add(LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/nearby/report", body: NearbyLogic.reportBody(user: p.id, reason: reason)).start(next: { _ in
                            toast(tx.reported)
                        }, error: { error in
                            showError(error)
                        }))
                    })
                }
                actions.append(TextAlertAction(type: .genericAction, title: tx.cancel, action: {}))
                presentImpl?(textAlertController(context: context, title: tx.reportTitle, text: "", actions: actions, actionLayout: .vertical))
            }),
            TextAlertAction(type: .destructiveAction, title: tx.hide, action: {
                presentImpl?(textAlertController(context: context, title: tx.hide, text: tx.hideConfirm(p.displayName), actions: [
                    TextAlertAction(type: .genericAction, title: tx.cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: tx.hide, action: {
                        requests.add(LuckgramBlocks.block(userId: p.id, displayName: p.displayName).start(next: { _ in
                            state.people = state.people?.filter { $0.id != p.id }
                            refresh()
                            toast(tx.hidden)
                        }, error: { error in
                            showError(error)
                        }))
                    })
                ]))
            }),
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {})
        ], actionLayout: .vertical))
    }

    func editBio() {
        let controller = promptController(context: context, text: tx.bio, titleFont: .bold, value: LuckgramNearby.bio, placeholder: tx.bioHint, characterLimit: NearbyLogic.bioMax, displayCharacterLimit: true, apply: { value in
            guard let value else {
                return
            }
            LuckgramNearby.bio = value
            refresh()
            if LuckgramNearby.isVisible {
                uploadCard()
            }
        })
        presentImpl?(controller)
    }

    let arguments = NearbyArguments(action: { id in
        if id >= idPerson {
            if let people = state.people, id - idPerson < people.count {
                showPerson(people[id - idPerson])
            }
            return
        }
        switch id {
        case idGoLink:
            pushImpl?(luckgramAccountController(context: context))
        case idGoUsername:
            openUrl("tg://settings/username")
        case idIntroOk:
            LuckgramNearby.introDone = true
            refresh()
            syncMe()
            reload()
        case idOpenSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                context.sharedContext.applicationBindings.openUrl(url.absoluteString)
            }
        case idRenew:
            setVisible(true)
        case idBio:
            editBio()
        case idRefresh:
            reload()
        case idBlocked:
            pushImpl?(luckgramBlockedUsersController(context: context))
        default:
            break
        }
    }, toggle: { id, value in
        if id == idVisible {
            setVisible(value)
        } else if id == idPhoto {
            LuckgramNearby.showPhoto = value
            refresh()
            if LuckgramNearby.isVisible {
                uploadCard()
            }
        }
    })

    let entries = updated.get() |> map { _ -> [NearbyEntry] in
        var e: [NearbyEntry] = []
        guard state.linked != nil else {
            e.append(.value(0, 0, tx.title, "", true))
            return e
        }
        switch precondition() {
        case .needLink:
            e.append(.header(0, 0, tx.needLinkTitle))
            e.append(.action(0, Int32(idGoLink), tx.goLink, .generic, true))
            e.append(.footer(0, 0, tx.needLinkText))
            return e
        case .needUsername:
            e.append(.header(0, 0, tx.needUsernameTitle))
            e.append(.action(0, Int32(idGoUsername), tx.goUsername, .generic, true))
            e.append(.footer(0, 0, tx.needUsernameText))
            return e
        case .ready:
            break
        }
        if !LuckgramNearby.introDone {
            e.append(.header(0, 0, tx.introTitle))
            e.append(.action(0, Int32(idIntroOk), tx.introContinue, .generic, true))
            e.append(.footer(0, 0, tx.introText))
            return e
        }
        let visible = LuckgramNearby.isVisible
        let canChange = !state.busy && !state.locating
        e.append(.header(0, 0, tx.myCard))
        e.append(.toggle(0, Int32(idVisible), tx.visibleSwitch, visible, canChange))
        if visible {
            e.append(.action(0, Int32(idRenew), tx.renew, .generic, canChange))
        }
        let bio = LuckgramNearby.bio
        e.append(.value(0, Int32(idBio), tx.bio, bio.isEmpty ? tx.bioEmpty : bio, false))
        e.append(.toggle(0, Int32(idPhoto), tx.showPhoto, LuckgramNearby.showPhoto, true))
        e.append(.value(0, Int32(idBlocked), LuckgramBlocks.texts.title, "", false))
        if visible, let exp = LuckgramNearby.expiresAt {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            e.append(.footer(0, 0, tx.visibleUntil(f.string(from: exp))))
        } else {
            e.append(.footer(0, 0, tx.visibleOffInfo))
        }

        if state.permissionDenied {
            e.append(.action(1, Int32(idOpenSettings), tx.openSettings, .generic, true))
            e.append(.footer(1, 0, tx.noPermission))
            return e
        }
        if let err = state.locationError {
            e.append(.action(1, Int32(idRefresh), tx.refresh, .generic, true))
            e.append(.footer(1, 0, err))
            return e
        }
        guard let people = state.people, !state.locating, !state.loadingList else {
            e.append(.value(1, 0, tx.loading, "", true))
            return e
        }
        if people.isEmpty {
            e.append(.action(1, Int32(idRefresh), tx.refresh, .generic, true))
            e.append(.footer(1, 0, tx.empty))
            return e
        }
        var section: Int32 = 1
        for g in NearbyLogic.group(people) {
            e.append(.header(section, 0, tx.bucket(g.bucket)))
            for p in g.people {
                let index = people.firstIndex(of: p) ?? 0
                e.append(.person(section, Int32(idPerson + index), p.displayName, p.bio, state.avatars[p.id]))
            }
            section += 1
        }
        e.append(.action(section, Int32(idRefresh), tx.refresh, .generic, canChange))
        return e
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, entries)
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tx.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        requests.dispose()
        listRequest.dispose()
        locator?.cancel()
    }
    let controller = ItemListController(context: context, state: signal)
    controllerRef = controller
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    var appearedOnce = false
    controller.didAppear = { _ in
        // Back from the account page or system settings.
        if appearedOnce && (state.linked != true || precondition() != .ready || (state.permissionDenied && LuckgramNearbyLocator.isAuthorized)) {
            state.permissionDenied = false
            loadAccount()
        }
        appearedOnce = true
    }
    loadAccount()
    return controller
}
