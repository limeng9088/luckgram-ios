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
import AccountUtils
import PromptUI
import LuckgramAccountsStore

/// Luckgram 09 (more accounts): strings, the limit alert and Settings → Manage accounts.
/// Same texts and layout as Android `LuckgramAccounts` / `LuckgramAccountsActivity`.
public enum LuckgramAccountsStrings {
    public static var limitReached: String { LuckgramStrings.pick("最多可登录 \(LuckgramAccountsStore.maxAccounts) 个账号", "You can log in to at most \(LuckgramAccountsStore.maxAccounts) accounts") }
    public static func showAll(_ count: Int) -> String { LuckgramStrings.pick("显示全部 \(count) 个账号", "Show all \(count) accounts") }
    public static var showLess: String { LuckgramStrings.pick("收起", "Show less") }
    public static var manage: String { LuckgramStrings.pick("管理账号", "Manage accounts") }
    public static var accounts: String { LuckgramStrings.pick("账号", "Accounts") }
    public static var manageInfo: String { LuckgramStrings.pick("拖动可以调整账号顺序，点按账号可以设置备注名。备注名只保存在本机，用于账号列表和通知标题。", "Drag to reorder accounts. Tap an account to set its name. Names are kept on this device only and are used in the account list and notification titles.") }
    public static var alias: String { LuckgramStrings.pick("备注名", "Name on this device") }
    public static var editAlias: String { LuckgramStrings.pick("设置备注名", "Set name") }
    public static var clearAlias: String { LuckgramStrings.pick("清除备注名", "Remove name") }
    public static var aliasHint: String { LuckgramStrings.pick("例如：工作", "e.g. Work") }
    public static var notifications: String { LuckgramStrings.pick("通知", "Notifications") }
    public static var notificationsInfo: String { LuckgramStrings.pick("关闭后，这个账号收到新消息时不再弹出通知。", "When off, new messages for this account don't show a notification.") }
}

/// Shown instead of Telegram Premium's upsell when 20 accounts are logged in.
public func luckgramAccountLimitController(context: AccountContext) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
    return textAlertController(context: context, title: nil, text: LuckgramAccountsStrings.limitReached, actions: [
        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
    ])
}

// MARK: - Manage accounts

private final class LuckgramAccountsArguments {
    let openAccount: (Int64) -> Void
    let toggleNotifications: (Int64, Bool) -> Void

    init(openAccount: @escaping (Int64) -> Void, toggleNotifications: @escaping (Int64, Bool) -> Void) {
        self.openAccount = openAccount
        self.toggleNotifications = toggleNotifications
    }
}

private enum LuckgramAccountsSection: Int32 {
    case accounts
    case notifications
}

private struct LuckgramAccountRow: Equatable {
    let accountId: Int64
    let context: AccountContext
    let peer: EnginePeer
    let title: String

    static func ==(lhs: LuckgramAccountRow, rhs: LuckgramAccountRow) -> Bool {
        return lhs.accountId == rhs.accountId && lhs.context === rhs.context && lhs.peer == rhs.peer && lhs.title == rhs.title
    }
}

private enum LuckgramAccountsEntry: ItemListNodeEntry {
    case accountsHeader(String)
    case account(index: Int, row: LuckgramAccountRow)
    case accountsInfo(String)
    case notificationsHeader(String)
    case notifications(index: Int, accountId: Int64, title: String, value: Bool)
    case notificationsInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .accountsHeader, .account, .accountsInfo:
            return LuckgramAccountsSection.accounts.rawValue
        case .notificationsHeader, .notifications, .notificationsInfo:
            return LuckgramAccountsSection.notifications.rawValue
        }
    }

    enum StableId: Hashable {
        case fixed(Int)
        case account(Int64)
        case notifications(Int64)
    }

    var stableId: StableId {
        switch self {
        case .accountsHeader:
            return .fixed(0)
        case let .account(_, row):
            return .account(row.accountId)
        case .accountsInfo:
            return .fixed(1)
        case .notificationsHeader:
            return .fixed(2)
        case let .notifications(_, accountId, _, _):
            return .notifications(accountId)
        case .notificationsInfo:
            return .fixed(3)
        }
    }

    /// Position in the list; account rows keep the order the user chose.
    private var sortIndex: Int {
        switch self {
        case .accountsHeader:
            return 0
        case let .account(index, _):
            return 100 + index
        case .accountsInfo:
            return 1000
        case .notificationsHeader:
            return 2000
        case let .notifications(index, _, _, _):
            return 2100 + index
        case .notificationsInfo:
            return 3000
        }
    }

    static func <(lhs: LuckgramAccountsEntry, rhs: LuckgramAccountsEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    static func ==(lhs: LuckgramAccountsEntry, rhs: LuckgramAccountsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.accountsHeader(a), .accountsHeader(b)):
            return a == b
        case let (.account(a1, a2), .account(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.accountsInfo(a), .accountsInfo(b)):
            return a == b
        case let (.notificationsHeader(a), .notificationsHeader(b)):
            return a == b
        case let (.notifications(a1, a2, a3, a4), .notifications(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.notificationsInfo(a), .notificationsInfo(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramAccountsArguments
        switch self {
        case let .accountsHeader(text), let .notificationsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .account(_, row):
            let peerContext = ItemListPeerItem.Context.custom(ItemListPeerItem.Context.Custom(
                accountPeerId: row.context.account.peerId,
                engine: row.context.engine,
                animationCache: row.context.animationCache,
                animationRenderer: row.context.animationRenderer,
                isPremiumDisabled: false,
                resolveInlineStickers: { fileIds in
                    return row.context.engine.stickers.resolveInlineStickers(fileIds: fileIds)
                }
            ))
            let accountId = row.accountId
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, context: peerContext, peer: row.peer, presence: nil, text: .none, label: .none, editing: ItemListPeerItemEditing(editable: false, editing: true, canBeReordered: true, revealed: false), switchValue: nil, enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.openAccount(accountId)
            }, setPeerIdWithRevealedOptions: { _, _ in }, removePeer: { _ in })
        case let .accountsInfo(text), let .notificationsInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .notifications(_, accountId, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleNotifications(accountId, value)
            })
        }
    }
}

private func luckgramAccountsEntries(rows: [LuckgramAccountRow]) -> [LuckgramAccountsEntry] {
    var entries: [LuckgramAccountsEntry] = []
    entries.append(.accountsHeader(LuckgramAccountsStrings.accounts.uppercased()))
    for (index, row) in rows.enumerated() {
        entries.append(.account(index: index, row: row))
    }
    entries.append(.accountsInfo(LuckgramAccountsStrings.manageInfo))
    entries.append(.notificationsHeader(LuckgramAccountsStrings.notifications.uppercased()))
    for (index, row) in rows.enumerated() {
        entries.append(.notifications(index: index, accountId: row.accountId, title: row.title, value: LuckgramAccountsStore.shared.isNotificationsEnabled(row.accountId)))
    }
    entries.append(.notificationsInfo(LuckgramAccountsStrings.notificationsInfo))
    return entries
}

/// Settings → Manage accounts: account order, a local name per account, a notification switch per account.
public func luckgramAccountsController(context: AccountContext) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    var rowsValue: [LuckgramAccountRow] = []

    let editAlias: (Int64) -> Void = { accountId in
        let controller = promptController(context: context, text: LuckgramAccountsStrings.alias, titleFont: .bold, value: LuckgramAccountsStore.shared.alias(accountId) ?? "", placeholder: LuckgramAccountsStrings.aliasHint, characterLimit: LuckgramAccountsStore.aliasMaxLength, apply: { value in
            if let value {
                LuckgramAccountsStore.shared.setAlias(accountId, value)
            }
        })
        presentImpl?(controller)
    }

    let arguments = LuckgramAccountsArguments(openAccount: { accountId in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        items.append(ActionSheetButtonItem(title: LuckgramAccountsStrings.editAlias, color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            editAlias(accountId)
        }))
        if LuckgramAccountsStore.shared.alias(accountId) != nil {
            items.append(ActionSheetButtonItem(title: LuckgramAccountsStrings.clearAlias, color: .destructive, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                LuckgramAccountsStore.shared.setAlias(accountId, nil)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentImpl?(actionSheet)
    }, toggleNotifications: { accountId, value in
        LuckgramAccountsStore.shared.setNotificationsEnabled(accountId, value)
    })

    let rows: Signal<[LuckgramAccountRow], NoError> = activeAccountsAndPeers(context: context, includePrimary: true)
    |> map { _, accounts -> [LuckgramAccountRow] in
        return accounts.map { accountContext, peer, _ in
            return LuckgramAccountRow(accountId: accountContext.account.id.int64, context: accountContext, peer: peer, title: peer.compactDisplayTitle)
        }
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, rows, LuckgramAccountsStore.shared.updated)
    |> map { presentationData, rows, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        rowsValue = rows
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramAccountsStrings.manage), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luckgramAccountsEntries(rows: rows), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    controller.setReorderEntry({ (fromIndex: Int, toIndex: Int, entries: [LuckgramAccountsEntry]) -> Signal<Bool, NoError> in
        guard fromIndex != toIndex, fromIndex < entries.count, case let .account(_, fromRow) = entries[fromIndex] else {
            return .single(false)
        }
        var order: [Int64] = entries.compactMap { entry in
            if case let .account(_, row) = entry {
                return row.accountId
            }
            return nil
        }
        guard let previousIndex = order.firstIndex(of: fromRow.accountId) else {
            return .single(false)
        }
        // Target position among the account rows: clamp moves onto the header or the footer.
        var targetIndex = 0
        if toIndex < entries.count {
            switch entries[toIndex] {
            case let .account(_, toRow):
                targetIndex = order.firstIndex(of: toRow.accountId) ?? previousIndex
            default:
                targetIndex = entries[toIndex] < entries[fromIndex] ? 0 : order.count - 1
            }
        } else {
            targetIndex = order.count - 1
        }
        if targetIndex == previousIndex {
            return .single(false)
        }
        order.remove(at: previousIndex)
        order.insert(fromRow.accountId, at: min(targetIndex, order.count))
        LuckgramAccountsStore.shared.setOrder(order, allAccounts: rowsValue.map(\.accountId))
        return .single(true)
    })
    return controller
}
