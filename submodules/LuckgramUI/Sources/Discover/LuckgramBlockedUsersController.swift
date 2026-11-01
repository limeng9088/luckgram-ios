import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI
import UndoUI
import LuckgramDiscover

// Blocked people (shared by People Nearby and Square): list and unblock.

private final class BlockedArguments {
    let action: (Int) -> Void

    init(action: @escaping (Int) -> Void) {
        self.action = action
    }
}

private enum BlockedEntry: ItemListNodeEntry {
    case user(Int32, String, String)
    case action(Int32, String, Bool)
    case footer(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case let .user(id, _, _), let .action(id, _, _):
            return id
        case .footer:
            return Int32.max
        }
    }

    static func ==(lhs: BlockedEntry, rhs: BlockedEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.user(a1, a2, a3), .user(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.action(a1, a2, a3), .action(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.footer(a), .footer(b)):
            return a == b
        default:
            return false
        }
    }

    static func <(lhs: BlockedEntry, rhs: BlockedEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! BlockedArguments
        switch self {
        case let .user(id, name, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: name, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.action(Int(id))
            })
        case let .action(id, title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.action(Int(id))
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class BlockedState {
    var ids: [String] = []
    var nextCursor: String?
    var loading = false
    var loadedOnce = false
    var failed = false
}

private let idLoading = 900000, idLoadMore = 900001, idRetry = 900002, idUser = 1000

public func luckgramBlockedUsersController(context: AccountContext) -> ViewController {
    let tx = LuckgramBlocks.texts
    let state = BlockedState()
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    let refresh = {
        version += 1
        updated.set(version)
    }
    let requests = DisposableSet()
    let listRequest = MetaDisposable()
    var presentImpl: ((ViewController) -> Void)?

    func toast(_ text: String) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }

    func showError(_ error: LuckgramAIError) {
        if error.code == LuckgramAIError.cancelled {
            return
        }
        toast(error.code == "not_linked" ? tx.notLinked : error.localizedMessage)
    }

    func label(_ id: String) -> String {
        return LuckgramBlocks.name(of: id) ?? tx.unknownUser
    }

    func load() {
        state.loading = true
        state.failed = false
        refresh()
        listRequest.set(LuckgramBlocks.list(cursor: state.nextCursor).start(next: { page in
            for id in page.ids where !state.ids.contains(id) {
                state.ids.append(id)
            }
            state.nextCursor = page.nextCursor
            state.loading = false
            state.loadedOnce = true
            refresh()
        }, error: { error in
            state.loading = false
            state.failed = true
            refresh()
            showError(error)
        }))
    }

    func confirmUnblock(_ id: String) {
        presentImpl?(textAlertController(context: context, title: tx.unblock, text: tx.unblockConfirm(label(id)), actions: [
            TextAlertAction(type: .genericAction, title: tx.cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: tx.unblock, action: {
                requests.add(LuckgramBlocks.unblock(userId: id).start(next: { _ in
                    state.ids.removeAll { $0 == id }
                    refresh()
                    toast(tx.unblocked)
                }, error: { error in
                    showError(error)
                }))
            })
        ]))
    }

    let arguments = BlockedArguments(action: { id in
        if id >= idUser {
            if id - idUser < state.ids.count {
                confirmUnblock(state.ids[id - idUser])
            }
            return
        }
        if (id == idLoadMore || id == idRetry) && !state.loading {
            load()
        }
    })

    let entries = updated.get() |> map { _ -> [BlockedEntry] in
        var e: [BlockedEntry] = []
        for (i, id) in state.ids.enumerated() {
            e.append(.user(Int32(idUser + i), label(id), tx.unblock))
        }
        if state.loading {
            e.append(.action(Int32(idLoading), tx.loading, false))
        } else if state.failed {
            e.append(.action(Int32(idRetry), tx.retry, true))
        } else if state.nextCursor != nil {
            e.append(.action(Int32(idLoadMore), tx.loadMore, true))
        }
        e.append(.footer(state.loadedOnce && state.ids.isEmpty && !state.loading ? tx.empty : tx.info))
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
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    load()
    return controller
}
