// Luckgram — private notes (spec 05).
// Licensed under GNU GPL v. 2 or later.

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import ItemListPeerItem
import PresentationDataUtils
import AccountContext
import LocalizedPeerData

private final class UserNotesListArguments {
    let context: AccountContext
    let updateQuery: (String) -> Void
    let openPeer: (EnginePeer) -> Void

    init(context: AccountContext, updateQuery: @escaping (String) -> Void, openPeer: @escaping (EnginePeer) -> Void) {
        self.context = context
        self.updateQuery = updateQuery
        self.openPeer = openPeer
    }
}

private enum UserNotesListSection: Int32 {
    case search
    case notes
}

private enum UserNotesListEntry: ItemListNodeEntry {
    case search(String, String)
    case note(Int32, EnginePeer, String)
    case empty(String)
    case info(String)

    var section: ItemListSectionId {
        switch self {
        case .search:
            return UserNotesListSection.search.rawValue
        case .note, .empty, .info:
            return UserNotesListSection.notes.rawValue
        }
    }

    var stableId: Int64 {
        switch self {
        case .search:
            return Int64.min
        case let .note(_, peer, _):
            return peer.id.toInt64()
        case .empty:
            return Int64.min + 1
        case .info:
            return Int64.max
        }
    }

    private var sortIndex: Int32 {
        switch self {
        case .search:
            return -2
        case .empty:
            return -1
        case let .note(index, _, _):
            return index
        case .info:
            return Int32.max
        }
    }

    static func ==(lhs: UserNotesListEntry, rhs: UserNotesListEntry) -> Bool {
        switch lhs {
        case let .search(lhsText, lhsPlaceholder):
            if case let .search(rhsText, rhsPlaceholder) = rhs, lhsText == rhsText, lhsPlaceholder == rhsPlaceholder {
                return true
            }
            return false
        case let .note(lhsIndex, lhsPeer, lhsText):
            if case let .note(rhsIndex, rhsPeer, rhsText) = rhs, lhsIndex == rhsIndex, lhsPeer == rhsPeer, lhsText == rhsText {
                return true
            }
            return false
        case let .empty(lhsText):
            if case let .empty(rhsText) = rhs, lhsText == rhsText {
                return true
            }
            return false
        case let .info(lhsText):
            if case let .info(rhsText) = rhs, lhsText == rhsText {
                return true
            }
            return false
        }
    }

    static func <(lhs: UserNotesListEntry, rhs: UserNotesListEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! UserNotesListArguments
        switch self {
        case let .search(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: ""), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), returnKeyType: .search, clearType: .always, sectionId: self.section, textUpdated: { updatedText in
                arguments.updateQuery(updatedText)
            }, action: {
            })
        case let .note(_, peer, text):
            let currentPresentationData = arguments.context.sharedContext.currentPresentationData.with { $0 }
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: currentPresentationData.dateTimeFormat, nameDisplayOrder: currentPresentationData.nameDisplayOrder, context: arguments.context, peer: peer, presence: nil, text: .text(text, .secondary), label: .none, editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false), switchValue: nil, enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.openPeer(peer)
            }, setPeerIdWithRevealedOptions: { _, _ in
            }, removePeer: { _ in
            })
        case let .empty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// The line of the note that matches the query, otherwise the first line.
private func noteSnippet(_ text: String, query: String) -> String {
    return LuckgramUserNotesText.snippet(note: text, query: query)
}

/// "All notes": every private note of the current account, searchable by note text and name.
public func luckgramUserNotesListController(context: AccountContext) -> ViewController {
    let store = LuckgramUserNotesStore.shared(context: context)

    let queryPromise = ValuePromise("", ignoreRepeated: true)

    // Re-read the store whenever a note changes (e.g. edited from a profile opened from this list).
    let notesSignal: Signal<[LuckgramUserNotesStore.Note], NoError> = Signal<Void, NoError>.single(Void())
    |> then(store.updates)
    |> deliverOnMainQueue
    |> map { _ -> [LuckgramUserNotesStore.Note] in
        return store.allNotes()
    }

    let notesWithPeers: Signal<[(LuckgramUserNotesStore.Note, EnginePeer)], NoError> = notesSignal
    |> mapToSignal { notes -> Signal<[(LuckgramUserNotesStore.Note, EnginePeer)], NoError> in
        let peerIds = notes.map { $0.peerId }
        return context.engine.data.get(EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
        |> map { peerMap -> [(LuckgramUserNotesStore.Note, EnginePeer)] in
            var result: [(LuckgramUserNotesStore.Note, EnginePeer)] = []
            for note in notes {
                if let maybePeer = peerMap[note.peerId], let peer = maybePeer {
                    result.append((note, peer))
                }
            }
            return result
        }
    }

    var pushImpl: ((ViewController) -> Void)?

    let arguments = UserNotesListArguments(context: context, updateQuery: { query in
        queryPromise.set(query)
    }, openPeer: { peer in
        if let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) {
            pushImpl?(controller)
        }
    })

    let signal = combineLatest(context.sharedContext.presentationData, notesWithPeers, queryPromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, notes, query -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = LuckgramUserNotesStrings(strings: presentationData.strings)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var entries: [UserNotesListEntry] = []
        entries.append(.search(query, strings.searchPlaceholder))

        var index: Int32 = 0
        for (note, peer) in notes {
            let title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            if !LuckgramUserNotesText.matches(query: trimmedQuery, note: note.text, name: title) {
                continue
            }
            entries.append(.note(index, peer, noteSnippet(note.text, query: trimmedQuery)))
            index += 1
        }
        if index == 0 {
            entries.append(.empty(trimmedQuery.isEmpty ? strings.noNotes : strings.noResults))
        } else {
            entries.append(.info(strings.editInfo))
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.allNotes), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
