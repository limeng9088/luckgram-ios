// Luckgram — keyword folders: create / edit screen (name, 1–10 keywords, chat types).

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

private final class KeywordFolderEditArguments {
    let updateName: (String) -> Void
    let updateKeyword: (Int, String) -> Void
    let addKeyword: () -> Void
    let toggleScope: (Int32) -> Void
    let delete: () -> Void

    init(updateName: @escaping (String) -> Void, updateKeyword: @escaping (Int, String) -> Void, addKeyword: @escaping () -> Void, toggleScope: @escaping (Int32) -> Void, delete: @escaping () -> Void) {
        self.updateName = updateName
        self.updateKeyword = updateKeyword
        self.addKeyword = addKeyword
        self.toggleScope = toggleScope
        self.delete = delete
    }
}

private enum KeywordFolderEditSection: Int32 {
    case name
    case keywords
    case scope
    case delete
}

private enum KeywordFolderEditEntry: ItemListNodeEntry {
    case nameHeader(String)
    case name(String, String)
    case keywordsHeader(String)
    case keyword(Int, String, String)
    case addKeyword(String)
    case keywordsInfo(String)
    case scopeHeader(String)
    case scope(Int32, String, Bool)
    case scopeInfo(String)
    case delete(String)

    var section: ItemListSectionId {
        switch self {
        case .nameHeader, .name:
            return KeywordFolderEditSection.name.rawValue
        case .keywordsHeader, .keyword, .addKeyword, .keywordsInfo:
            return KeywordFolderEditSection.keywords.rawValue
        case .scopeHeader, .scope, .scopeInfo:
            return KeywordFolderEditSection.scope.rawValue
        case .delete:
            return KeywordFolderEditSection.delete.rawValue
        }
    }

    var stableId: Int {
        switch self {
        case .nameHeader:
            return 0
        case .name:
            return 1
        case .keywordsHeader:
            return 10
        case let .keyword(index, _, _):
            return 11 + index
        case .addKeyword:
            return 100
        case .keywordsInfo:
            return 101
        case .scopeHeader:
            return 200
        case let .scope(flag, _, _):
            return 201 + Int(flag)
        case .scopeInfo:
            return 300
        case .delete:
            return 400
        }
    }

    static func <(lhs: KeywordFolderEditEntry, rhs: KeywordFolderEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! KeywordFolderEditArguments
        switch self {
        case let .nameHeader(text), let .keywordsHeader(text), let .scopeHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .name(value, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: ""), text: value, placeholder: placeholder, type: .regular(capitalization: true, autocorrection: false), spacing: 0.0, maxLength: 12, sectionId: self.section, textUpdated: { updatedText in
                arguments.updateName(updatedText)
            }, action: {})
        case let .keyword(index, value, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: ""), text: value, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), spacing: 0.0, clearType: .always, maxLength: 64, sectionId: self.section, textUpdated: { updatedText in
                arguments.updateKeyword(index, updatedText)
            }, action: {})
        case let .addKeyword(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.addKeyword()
            })
        case let .keywordsInfo(text), let .scopeInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .scope(flag, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { _ in
                arguments.toggleScope(flag)
            })
        case let .delete(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.delete()
            })
        }
    }
}

private struct KeywordFolderEditState: Equatable {
    var name: String
    var keywords: [String]
    var scope: Int32
}

private func keywordFolderEditEntries(strings: PresentationStrings, state: KeywordFolderEditState, isNew: Bool) -> [KeywordFolderEditEntry] {
    var entries: [KeywordFolderEditEntry] = []
    entries.append(.nameHeader(KeywordFolderStrings.nameHeader(strings)))
    entries.append(.name(state.name, KeywordFolderStrings.nameHint(strings)))
    entries.append(.keywordsHeader(KeywordFolderStrings.keywordsHeader(strings)))
    for i in 0 ..< state.keywords.count {
        entries.append(.keyword(i, state.keywords[i], KeywordFolderStrings.keywordHint(strings)))
    }
    // Always shown (like Android); tapping it at the limit explains the limit.
    entries.append(.addKeyword(KeywordFolderStrings.addKeyword(strings)))
    entries.append(.keywordsInfo(KeywordFolderStrings.keywordsInfo(strings)))
    entries.append(.scopeHeader(KeywordFolderStrings.scopeHeader(strings)))
    entries.append(.scope(0, KeywordFolderStrings.scopeAll(strings), state.scope == KeywordFolder.scopeAll))
    entries.append(.scope(KeywordFolder.scopePrivate, KeywordFolderStrings.scopePrivate(strings), state.scope & KeywordFolder.scopePrivate != 0))
    entries.append(.scope(KeywordFolder.scopeGroups, KeywordFolderStrings.scopeGroups(strings), state.scope & KeywordFolder.scopeGroups != 0))
    entries.append(.scope(KeywordFolder.scopeChannels, KeywordFolderStrings.scopeChannels(strings), state.scope & KeywordFolder.scopeChannels != 0))
    entries.append(.scopeInfo(KeywordFolderStrings.settingsInfo(strings)))
    if !isNew {
        entries.append(.delete(KeywordFolderStrings.delete(strings)))
    }
    return entries
}

private func normalizedKeywords(_ keywords: [String]) -> [String] {
    var result: [String] = []
    for keyword in keywords {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            continue
        }
        if result.count < keywordFoldersMaxKeywords {
            result.append(trimmed)
        }
    }
    return result
}

/// Asks to delete a keyword folder; the chats in it are not touched.
public func presentKeywordFolderDeletion(context: AccountContext, folderId: Int32, present: @escaping (ViewController) -> Void, completion: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present(textAlertController(context: context, title: KeywordFolderStrings.deleteAlertTitle(presentationData.strings), text: KeywordFolderStrings.deleteAlertText(presentationData.strings), actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
            let _ = (updateKeywordFolders(context: context, { folders in
                return folders.filter { $0.id != folderId }
            })
            |> deliverOnMainQueue).startStandalone(completed: {
                completion()
            })
        })
    ]))
}

/// Editor for a keyword folder. `folderId == nil` creates a new one.
public func keywordFolderEditController(context: AccountContext, folderId: Int32?) -> ViewController {
    let initialState = KeywordFolderEditState(name: "", keywords: [""], scope: KeywordFolder.scopeAll)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((KeywordFolderEditState) -> KeywordFolderEditState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var dismissImpl: (() -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var showErrorImpl: ((String) -> Void)?

    if let folderId {
        let _ = (keywordFolders(context: context)
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { folders in
            guard let folder = folders.first(where: { $0.id == folderId }) else {
                return
            }
            updateState { _ in
                return KeywordFolderEditState(name: folder.name, keywords: folder.keywords.isEmpty ? [""] : folder.keywords, scope: folder.scope)
            }
        })
    }

    let arguments = KeywordFolderEditArguments(updateName: { value in
        updateState { state in
            var state = state
            state.name = value
            return state
        }
    }, updateKeyword: { index, value in
        updateState { state in
            var state = state
            if index >= 0 && index < state.keywords.count {
                state.keywords[index] = value
            }
            return state
        }
    }, addKeyword: {
        if stateValue.with({ $0.keywords.count }) >= keywordFoldersMaxKeywords {
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            showErrorImpl?(KeywordFolderStrings.keywordsLimit(strings))
            return
        }
        updateState { state in
            var state = state
            if state.keywords.count < keywordFoldersMaxKeywords {
                state.keywords.append("")
            }
            return state
        }
    }, toggleScope: { flag in
        updateState { state in
            var state = state
            if flag == 0 {
                state.scope = state.scope == KeywordFolder.scopeAll ? 0 : KeywordFolder.scopeAll
            } else {
                state.scope ^= flag
            }
            return state
        }
    }, delete: {
        guard let folderId else {
            return
        }
        presentKeywordFolderDeletion(context: context, folderId: folderId, present: { c in
            presentImpl?(c)
        }, completion: {
            dismissImpl?()
        })
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings

        let leftButton = ItemListNavigationButton(content: .text(strings.Common_Cancel), style: .regular, enabled: true, action: {
            dismissImpl?()
        })
        let rightButton = ItemListNavigationButton(content: .text(strings.Common_Done), style: .bold, enabled: true, action: {
            // "Done" is always enabled (like Android); tapping it says what is missing.
            let current = stateValue.with { $0 }
            let keywords = normalizedKeywords(current.keywords)
            let name = current.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                showErrorImpl?(KeywordFolderStrings.errorName(strings))
                return
            }
            if keywords.isEmpty {
                showErrorImpl?(KeywordFolderStrings.errorKeywords(strings))
                return
            }
            if current.scope & KeywordFolder.scopeAll == 0 {
                showErrorImpl?(KeywordFolderStrings.errorScope(strings))
                return
            }
            let scope = current.scope
            let _ = (updateKeywordFolders(context: context, { folders in
                var folders = folders
                if let folderId, let index = folders.firstIndex(where: { $0.id == folderId }) {
                    folders[index].name = name
                    folders[index].keywords = keywords
                    folders[index].scope = scope
                } else if folders.count < keywordFoldersMaxCount {
                    let newId = (folders.map { $0.id }.max() ?? 0) + 1
                    folders.append(KeywordFolder(id: newId, name: name, keywords: keywords, scope: scope, position: Int32.max))
                }
                return folders
            })
            |> deliverOnMainQueue).startStandalone(completed: {
                dismissImpl?()
            })
        })

        let title = folderId == nil ? KeywordFolderStrings.newFolder(strings) : KeywordFolderStrings.editFolder(strings)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: leftButton, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: keywordFolderEditEntries(strings: strings, state: state, isNew: folderId == nil), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        controller?.dismiss()
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    showErrorImpl = { [weak controller] text in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
    }
    return controller
}

/// Opens the editor for a new keyword folder, or tells the user the limit is reached.
public func openNewKeywordFolder(context: AccountContext, push: @escaping (ViewController) -> Void, present: @escaping (ViewController) -> Void) {
    let _ = (keywordFolders(context: context)
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { folders in
        if folders.count >= keywordFoldersMaxCount {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            present(textAlertController(context: context, title: nil, text: KeywordFolderStrings.limitReached(presentationData.strings), actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
        } else {
            push(keywordFolderEditController(context: context, folderId: nil))
        }
    })
}
