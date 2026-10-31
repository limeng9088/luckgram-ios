// Luckgram — private notes (spec 05).
// Licensed under GNU GPL v. 2 or later.

import Foundation
import ComponentFlow
import TelegramCore
import TelegramPresentationData
import AccountContext

/// Whether a private note can be attached to this peer (not to yourself / Saved Messages).
public func luckgramUserNotesAvailable(context: AccountContext, peerId: EnginePeer.Id) -> Bool {
    return LuckgramUserNotesStore.isEnabled && peerId != context.account.peerId
}

/// Header panel for the chat screen, or nil when there is no note (or the feature is off).
public func luckgramUserNoteHeaderPanel(context: AccountContext, peerId: EnginePeer.Id, theme: PresentationTheme, strings: PresentationStrings, edit: @escaping () -> Void) -> AnyComponent<Empty>? {
    guard luckgramUserNotesAvailable(context: context, peerId: peerId) else {
        return nil
    }
    let store = LuckgramUserNotesStore.shared(context: context)
    guard let text = store.note(peerId: peerId) else {
        return nil
    }
    let isExpanded = store.isBarExpanded(peerId: peerId)
    return AnyComponent(LuckgramUserNoteHeaderPanelComponent(
        theme: theme,
        strings: LuckgramUserNotesStrings(strings: strings),
        text: text,
        isExpanded: isExpanded,
        toggleExpanded: {
            store.setBarExpanded(peerId: peerId, expanded: !isExpanded)
        },
        edit: edit
    ))
}

/// Values for the "Private note" row on a profile page.
public struct LuckgramUserNoteProfileRow {
    public let label: String
    public let rightLabel: String
    public let text: String
    public let hasNote: Bool
}

public func luckgramUserNoteProfileRow(context: AccountContext, peerId: EnginePeer.Id, strings: PresentationStrings) -> LuckgramUserNoteProfileRow? {
    guard luckgramUserNotesAvailable(context: context, peerId: peerId) else {
        return nil
    }
    let noteStrings = LuckgramUserNotesStrings(strings: strings)
    let note = LuckgramUserNotesStore.shared(context: context).note(peerId: peerId)
    return LuckgramUserNoteProfileRow(label: noteStrings.rowTitle, rightLabel: noteStrings.onlyYou, text: note ?? noteStrings.addNote, hasNote: note != nil)
}
