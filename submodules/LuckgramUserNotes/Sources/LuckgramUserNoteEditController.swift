// Luckgram — private notes (spec 05).
// Licensed under GNU GPL v. 2 or later.

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

private final class UserNoteEditArguments {
    let updateText: (String) -> Void
    let textTooLong: () -> Void
    let delete: () -> Void
    let openAllNotes: () -> Void

    init(updateText: @escaping (String) -> Void, textTooLong: @escaping () -> Void, delete: @escaping () -> Void, openAllNotes: @escaping () -> Void) {
        self.updateText = updateText
        self.textTooLong = textTooLong
        self.delete = delete
        self.openAllNotes = openAllNotes
    }
}

private enum UserNoteEditSection: Int32 {
    case text
    case delete
    case all
}

private enum UserNoteEditEntry: ItemListNodeEntry {
    case text(String, String)
    case info(String)
    case delete(String)
    case allNotes(String)

    var section: ItemListSectionId {
        switch self {
        case .text, .info:
            return UserNoteEditSection.text.rawValue
        case .delete:
            return UserNoteEditSection.delete.rawValue
        case .allNotes:
            return UserNoteEditSection.all.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .text:
            return 0
        case .info:
            return 1
        case .delete:
            return 2
        case .allNotes:
            return 3
        }
    }

    static func ==(lhs: UserNoteEditEntry, rhs: UserNoteEditEntry) -> Bool {
        switch lhs {
        case let .text(lhsText, lhsPlaceholder):
            if case let .text(rhsText, rhsPlaceholder) = rhs, lhsText == rhsText, lhsPlaceholder == rhsPlaceholder {
                return true
            }
            return false
        case let .info(lhsText):
            if case let .info(rhsText) = rhs, lhsText == rhsText {
                return true
            }
            return false
        case let .delete(lhsText):
            if case let .delete(rhsText) = rhs, lhsText == rhsText {
                return true
            }
            return false
        case let .allNotes(lhsText):
            if case let .allNotes(rhsText) = rhs, lhsText == rhsText {
                return true
            }
            return false
        }
    }

    static func <(lhs: UserNoteEditEntry, rhs: UserNoteEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! UserNoteEditArguments
        switch self {
        case let .text(text, placeholder):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: placeholder, maxLength: ItemListMultilineInputItemTextLimit(value: LuckgramUserNotesStore.maxLength, display: true), sectionId: self.section, style: .blocks, minimalHeight: 120.0, textUpdated: { updatedText in
                arguments.updateText(updatedText)
            }, shouldUpdateText: { newText in
                // Same as Android: refuse input past the limit and say why.
                if !LuckgramUserNotesText.isWithinLimit(newText) {
                    arguments.textTooLong()
                    return false
                }
                return true
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .delete(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.delete()
            })
        case let .allNotes(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.openAllNotes()
            })
        }
    }
}

/// Editor for the private note of one peer. `completion` is called after the note was saved or deleted.
public func luckgramUserNoteEditController(context: AccountContext, peerId: EnginePeer.Id, completion: (() -> Void)? = nil) -> ViewController {
    let store = LuckgramUserNotesStore.shared(context: context)
    let initialText = store.note(peerId: peerId) ?? ""
    let hadNote = !initialText.isEmpty

    let textPromise = ValuePromise(initialText, ignoreRepeated: true)
    let textValue = Atomic(value: initialText)

    var dismissImpl: (() -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    var savedImpl: (() -> Void)?

    var lastTooLongToast: Double = 0.0
    let arguments = UserNoteEditArguments(updateText: { text in
        let _ = textValue.swap(text)
        textPromise.set(text)
    }, textTooLong: {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTooLongToast < 2.0 {
            return
        }
        lastTooLongToast = now
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = LuckgramUserNotesStrings(strings: presentationData.strings)
        presentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: strings.tooLong, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }, delete: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = LuckgramUserNotesStrings(strings: presentationData.strings)
        presentImpl?(textAlertController(context: context, title: strings.deleteNote, text: strings.deleteConfirm, actions: [
            TextAlertAction(type: .genericAction, title: strings.cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: strings.delete, action: {
                store.setNote(peerId: peerId, text: nil)
                completion?()
                savedImpl?()
                dismissImpl?()
            })
        ]))
    }, openAllNotes: {
        pushImpl?(luckgramUserNotesListController(context: context))
    })

    let signal = combineLatest(context.sharedContext.presentationData, textPromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, text -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = LuckgramUserNotesStrings(strings: presentationData.strings)
        let rightNavigationButton = ItemListNavigationButton(content: .text(strings.done), style: .bold, enabled: true, action: {
            store.setNote(peerId: peerId, text: textValue.with { $0 })
            completion?()
            savedImpl?()
            dismissImpl?()
        })

        var entries: [UserNoteEditEntry] = []
        entries.append(.text(text, strings.editPlaceholder))
        entries.append(.info(strings.editInfo))
        if hadNote {
            entries.append(.delete(strings.deleteNote))
        }
        entries.append(.allNotes(strings.allNotes))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.editTitle), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        controller?.dismiss()
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    // Same as Android: leaving with unsaved changes asks first.
    var didConfirmDiscard = false
    savedImpl = {
        didConfirmDiscard = true
    }
    controller.attemptNavigation = { [weak controller] action in
        let current = textValue.with { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
        if didConfirmDiscard || current == initialText.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = LuckgramUserNotesStrings(strings: presentationData.strings)
        controller?.present(textAlertController(context: context, title: nil, text: strings.discardTitle, actions: [
            TextAlertAction(type: .genericAction, title: strings.cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: strings.discard, action: {
                didConfirmDiscard = true
                action()
            })
        ]), in: .window(.root))
        return false
    }
    return controller
}
