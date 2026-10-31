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
import UndoUI
import PasscodeCore
import LuckgramAccountsStore

/// Luckgram 12 (hidden chats): hide chats from the chat list without deleting or leaving them.
/// Hidden chats appear in no list or folder, are left out of search and the badge, and don't
/// notify unless the user chose otherwise. Same behaviour as Android `LuckgramHiddenChats`.
public enum LuckgramHiddenChats {
    public static let featureKey = "hidden_chats"

    public enum Strings {
        public static var title: String { LuckgramStrings.pick("隐藏的聊天", "Hidden chats") }
        public static var hide: String { LuckgramStrings.pick("隐藏", "Hide") }
        public static var unhide: String { LuckgramStrings.pick("取消隐藏", "Unhide") }
        public static var hidden: String { LuckgramStrings.pick("已隐藏", "Hidden") }
        public static var undo: String { LuckgramStrings.pick("撤销", "Undo") }
        public static var unhidden: String { LuckgramStrings.pick("已取消隐藏", "Unhidden") }
        public static var hint: String { LuckgramStrings.pick("在聊天列表下拉可以看到隐藏的聊天", "Pull down the chat list to see hidden chats") }
        public static var searchHidden: String { LuckgramStrings.pick("在隐藏的聊天中搜索", "Search in hidden chats") }
        public static func searchMatches(_ count: Int) -> String { LuckgramStrings.pick("\(count) 个隐藏的聊天匹配", "\(count) hidden chat(s) match") }
        public static var lock: String { LuckgramStrings.pick("进入时需要验证", "Require passcode to open") }
        public static var lockInfo: String { LuckgramStrings.pick("打开隐藏的聊天前要求输入应用密码或使用面容 / 指纹。需要先开启 Telegram 的密码锁。", "Ask for the app passcode or Face ID / fingerprint before opening hidden chats. Telegram's Passcode Lock must be on first.") }
        public static var notify: String { LuckgramStrings.pick("隐藏的聊天照常通知", "Notify for hidden chats") }
        public static var notifyInfo: String { LuckgramStrings.pick("关闭时，隐藏聊天的新消息不弹通知，也不计入角标。", "When off, new messages in hidden chats show no notification and don't count in the badge.") }
        public static var open: String { LuckgramStrings.pick("打开隐藏的聊天", "Open hidden chats") }
        public static var empty: String { LuckgramStrings.pick("在聊天上左滑选择「隐藏」，它就会出现在这里。", "Swipe a chat and choose Hide; it will show up here.") }
        public static var enterPasscode: String { LuckgramStrings.pick("输入应用密码", "Enter the app passcode") }
        public static var wrongPasscode: String { LuckgramStrings.pick("密码不正确", "Incorrect passcode") }
    }

    public static var isEnabled: Bool {
        return LuckgramHiddenChatsStore.shared.isEnabled
    }

    /// Mirrors the feature switch into the store (the notification extension reads it from there).
    public static func install() {
        let _ = LuckgramSettings.shared.isEnabledSignal(featureKey).start(next: { value in
            LuckgramHiddenChatsStore.shared.setEnabled(value)
        })
    }

    // MARK: - Hide / unhide

    public static func hide(context: AccountContext, peerId: EnginePeer.Id) {
        let accountPeerId = context.account.peerId.toInt64()
        LuckgramHiddenChatsStore.shared.setHidden(accountPeerId: accountPeerId, peerId: peerId.toInt64(), true)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        let hint = LuckgramHiddenChatsStore.shared.takeFirstHint() ? Strings.hint : nil
        let controller = UndoOverlayController(presentationData: presentationData, content: .info(title: hint == nil ? nil : Strings.hidden, text: hint ?? Strings.hidden, timeout: nil, customUndoText: Strings.undo), action: { action in
            if case .undo = action {
                LuckgramHiddenChatsStore.shared.setHidden(accountPeerId: accountPeerId, peerId: peerId.toInt64(), false)
            }
            return false
        })
        context.sharedContext.mainWindow?.present(controller, on: .root)
    }

    public static func unhide(context: AccountContext, peerId: EnginePeer.Id) {
        let accountPeerId = context.account.peerId.toInt64()
        LuckgramHiddenChatsStore.shared.setHidden(accountPeerId: accountPeerId, peerId: peerId.toInt64(), false)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: Strings.unhidden, timeout: nil, customUndoText: Strings.undo), action: { action in
            if case .undo = action {
                LuckgramHiddenChatsStore.shared.setHidden(accountPeerId: accountPeerId, peerId: peerId.toInt64(), true)
            }
            return false
        })
        context.sharedContext.mainWindow?.present(controller, on: .root)
    }

    // MARK: - Search

    private static var skippedSearchMatches = 0
    private static var skippedSearchTimer: SwiftSignalKit.Timer?

    /// True when the peer is hidden and the user hasn't asked to search hidden chats. Counts the
    /// skipped matches and, shortly after, offers "Search in hidden chats".
    public static func skipInSearch(context: AccountContext, peerId: EnginePeer.Id) -> Bool {
        guard !LuckgramHiddenChatsStore.shared.includeHiddenInSearch, LuckgramHiddenChatsStore.shared.isHidden(accountPeerId: context.account.peerId.toInt64(), peerId: peerId.toInt64()) else {
            return false
        }
        Queue.mainQueue().async {
            skippedSearchMatches += 1
            skippedSearchTimer?.invalidate()
            let timer = SwiftSignalKit.Timer(timeout: 0.4, repeat: false, completion: {
                let count = skippedSearchMatches
                skippedSearchMatches = 0
                if count > 0 {
                    offerSearchInHidden(context: context, count: count)
                }
            }, queue: Queue.mainQueue())
            skippedSearchTimer = timer
            timer.start()
        }
        return true
    }

    private static func offerSearchInHidden(context: AccountContext, count: Int) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        let controller = UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: Strings.searchMatches(count), timeout: 5.0, customUndoText: Strings.searchHidden), action: { action in
            if case .undo = action {
                LuckgramHiddenChatsStore.shared.setIncludeHiddenInSearch(true)
            }
            return false
        })
        context.sharedContext.mainWindow?.present(controller, on: .root)
    }

    // MARK: - Opening the list

    /// Called when the chat list is pulled down past the threshold.
    public static func openFromPull(context: AccountContext) {
        guard LuckgramHiddenChatsStore.shared.hasHidden(accountPeerId: context.account.peerId.toInt64()) else {
            return
        }
        open(context: context, push: { controller in
            (context.sharedContext.mainWindow?.viewController as? NavigationController)?.pushViewController(controller)
        })
    }

    /// Opens the hidden chats list, after the app passcode when the user asked for that.
    public static func open(context: AccountContext, push: @escaping (ViewController) -> Void) {
        let sharedContext = context.sharedContext
        if LuckgramHiddenChatsStore.shared.isLockEnabled {
            let _ = (sharedContext.accountManager.transaction { transaction -> PostboxAccessChallengeData in
                return transaction.getAccessChallengeData()
            }
            |> deliverOnMainQueue).start(next: { challenge in
                if case .none = challenge {
                    push(luckgramHiddenChatsListController(context: context))
                } else {
                    luckgramRequestAppPasscode(sharedContext: sharedContext, challenge: challenge, completion: {
                        push(luckgramHiddenChatsListController(context: context))
                    })
                }
            })
        } else {
            push(luckgramHiddenChatsListController(context: context))
        }
    }
}

// MARK: - App passcode prompt (shared with 11)

func luckgramPasscodeReference(from challenge: PostboxAccessChallengeData) throws -> PasscodeCredentialReference? {
    switch challenge {
    case .none:
        return nil
    case let .numericalPassword(value):
        return try PasscodeCredentialStore.shared.migrateLegacy(code: value, kind: value.count == 6 ? .digits6 : .digits4)
    case let .plaintextPassword(value):
        return try PasscodeCredentialStore.shared.migrateLegacy(code: value, kind: .alphanumeric)
    case let .secured(id, kind):
        return PasscodeCredentialReference(id: id, kind: PasscodeKind(rawValue: kind.rawValue) ?? .alphanumeric)
    }
}

/// Asks for the app passcode and verifies it with Telegram's credential store (a wrong code counts
/// as a failed attempt there, like on the lock screen).
func luckgramRequestAppPasscode(sharedContext: SharedAccountContext, challenge: PostboxAccessChallengeData, completion: @escaping () -> Void) {
    let numeric: Bool
    switch challenge {
    case .numericalPassword:
        numeric = true
    case let .secured(_, kind):
        numeric = kind != .alphanumeric
    default:
        numeric = false
    }
    let alert = UIAlertController(title: LuckgramHiddenChats.Strings.enterPasscode, message: nil, preferredStyle: .alert)
    alert.addTextField { field in
        field.isSecureTextEntry = true
        field.keyboardType = numeric ? .numberPad : .default
    }
    alert.addAction(UIAlertAction(title: LuckgramStrings.cancel, style: .cancel))
    alert.addAction(UIAlertAction(title: LuckgramStrings.ok, style: .default, handler: { [weak alert] _ in
        let code = alert?.textFields?.first?.text ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let ok: Bool
            do {
                let session = try PasscodeCredentialStore.shared.verify(code, reference: try luckgramPasscodeReference(from: challenge), scope: .settings)
                session.invalidate()
                ok = true
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                if ok {
                    completion()
                } else {
                    let failed = UIAlertController(title: nil, message: LuckgramHiddenChats.Strings.wrongPasscode, preferredStyle: .alert)
                    failed.addAction(UIAlertAction(title: LuckgramStrings.ok, style: .default))
                    sharedContext.applicationBindings.presentNativeController(failed)
                }
            }
        }
    }))
    sharedContext.applicationBindings.presentNativeController(alert)
}

// MARK: - The hidden chats list

private final class LuckgramHiddenListArguments {
    let context: AccountContext
    let open: (EnginePeer) -> Void
    let unhide: (EnginePeer.Id) -> Void
    let setRevealed: (EnginePeer.Id?) -> Void

    init(context: AccountContext, open: @escaping (EnginePeer) -> Void, unhide: @escaping (EnginePeer.Id) -> Void, setRevealed: @escaping (EnginePeer.Id?) -> Void) {
        self.context = context
        self.open = open
        self.unhide = unhide
        self.setRevealed = setRevealed
    }
}

private enum LuckgramHiddenListEntry: ItemListNodeEntry {
    case peer(index: Int, peer: EnginePeer, revealed: Bool)
    case empty(String)

    var section: ItemListSectionId {
        return 0
    }

    enum StableId: Hashable {
        case peer(EnginePeer.Id)
        case empty
    }

    var stableId: StableId {
        switch self {
        case let .peer(_, peer, _):
            return .peer(peer.id)
        case .empty:
            return .empty
        }
    }

    private var sortIndex: Int {
        switch self {
        case let .peer(index, _, _):
            return index
        case .empty:
            return 0
        }
    }

    static func <(lhs: LuckgramHiddenListEntry, rhs: LuckgramHiddenListEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    static func ==(lhs: LuckgramHiddenListEntry, rhs: LuckgramHiddenListEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.peer(a1, a2, a3), .peer(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.empty(a), .empty(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramHiddenListArguments
        switch self {
        case let .peer(_, peer, revealed):
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, context: .account(arguments.context), peer: peer, presence: nil, text: .none, label: .none, editing: ItemListPeerItemEditing(editable: true, editing: false, revealed: revealed), revealOptions: ItemListPeerItemRevealOptions(options: [ItemListPeerItemRevealOption(type: .accent, title: LuckgramHiddenChats.Strings.unhide, action: {
                arguments.unhide(peer.id)
            })]), switchValue: nil, enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.open(peer)
            }, setPeerIdWithRevealedOptions: { peerId, _ in
                arguments.setRevealed(peerId)
            }, removePeer: { peerId in
                arguments.unhide(peerId)
            })
        case let .empty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

public func luckgramHiddenChatsListController(context: AccountContext) -> ViewController {
    let accountPeerId = context.account.peerId.toInt64()
    let revealed = ValuePromise<EnginePeer.Id?>(nil, ignoreRepeated: true)
    var navigationImpl: (() -> NavigationController?)?

    let arguments = LuckgramHiddenListArguments(context: context, open: { peer in
        guard let navigationController = navigationImpl?() else {
            return
        }
        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
    }, unhide: { peerId in
        LuckgramHiddenChats.unhide(context: context, peerId: peerId)
    }, setRevealed: { peerId in
        revealed.set(peerId)
    })

    let peers: Signal<[EnginePeer], NoError> = LuckgramHiddenChatsStore.shared.updated
    |> mapToSignal { _ -> Signal<[EnginePeer], NoError> in
        let ids = LuckgramHiddenChatsStore.shared.hiddenPeerIds(accountPeerId: accountPeerId).map { EnginePeer.Id($0) }
        if ids.isEmpty {
            return .single([])
        }
        return context.engine.data.subscribe(EngineDataMap(ids.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
        |> map { map -> [EnginePeer] in
            return ids.compactMap { map[$0] ?? nil }
        }
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, peers, revealed.get())
    |> map { presentationData, peers, revealed -> (ItemListControllerState, (ItemListNodeState, Any)) in
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        var entries: [LuckgramHiddenListEntry] = []
        if peers.isEmpty {
            entries.append(.empty(LuckgramHiddenChats.Strings.empty))
        }
        for (index, peer) in peers.enumerated() {
            entries.append(.peer(index: index, peer: peer, revealed: revealed == peer.id))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramHiddenChats.Strings.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    navigationImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    return controller
}

// MARK: - Luckgram Features → Hidden chats

private final class LuckgramHiddenSettingsArguments {
    let open: () -> Void
    let toggleLock: (Bool) -> Void
    let toggleNotify: (Bool) -> Void

    init(open: @escaping () -> Void, toggleLock: @escaping (Bool) -> Void, toggleNotify: @escaping (Bool) -> Void) {
        self.open = open
        self.toggleLock = toggleLock
        self.toggleNotify = toggleNotify
    }
}

private enum LuckgramHiddenSettingsEntry: ItemListNodeEntry {
    case open(String)
    case openInfo(String)
    case lock(String, Bool, Bool)
    case lockInfo(String)
    case notify(String, Bool)
    case notifyInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .open, .openInfo:
            return 0
        case .lock, .lockInfo:
            return 1
        case .notify, .notifyInfo:
            return 2
        }
    }

    var stableId: Int {
        switch self {
        case .open:
            return 0
        case .openInfo:
            return 1
        case .lock:
            return 2
        case .lockInfo:
            return 3
        case .notify:
            return 4
        case .notifyInfo:
            return 5
        }
    }

    static func <(lhs: LuckgramHiddenSettingsEntry, rhs: LuckgramHiddenSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: LuckgramHiddenSettingsEntry, rhs: LuckgramHiddenSettingsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.open(a), .open(b)), let (.openInfo(a), .openInfo(b)), let (.lockInfo(a), .lockInfo(b)), let (.notifyInfo(a), .notifyInfo(b)):
            return a == b
        case let (.lock(a1, a2, a3), .lock(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.notify(a1, a2), .notify(b1, b2)):
            return a1 == b1 && a2 == b2
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramHiddenSettingsArguments
        switch self {
        case let .open(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.open()
            })
        case let .openInfo(text), let .lockInfo(text), let .notifyInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .lock(text, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleLock(value)
            })
        case let .notify(text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleNotify(value)
            })
        }
    }
}

public func luckgramHiddenChatsSettingsController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?

    let arguments = LuckgramHiddenSettingsArguments(open: {
        LuckgramHiddenChats.open(context: context, push: { c in pushImpl?(c) })
    }, toggleLock: { value in
        LuckgramHiddenChatsStore.shared.setLockEnabled(value)
    }, toggleNotify: { value in
        LuckgramHiddenChatsStore.shared.setNotifyEnabled(value)
    })

    let passcodeOn = context.sharedContext.accountManager.accessChallengeData()
    |> map { view -> Bool in
        if case .none = view.data {
            return false
        }
        return true
    }
    |> distinctUntilChanged

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, LuckgramHiddenChatsStore.shared.updated, passcodeOn)
    |> map { presentationData, _, passcodeOn -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        let entries: [LuckgramHiddenSettingsEntry] = [
            .open(LuckgramHiddenChats.Strings.open),
            .openInfo(LuckgramHiddenChats.Strings.empty),
            .lock(LuckgramHiddenChats.Strings.lock, LuckgramHiddenChatsStore.shared.isLockEnabled && passcodeOn, passcodeOn),
            .lockInfo(LuckgramHiddenChats.Strings.lockInfo),
            .notify(LuckgramHiddenChats.Strings.notify, LuckgramHiddenChatsStore.shared.isNotifyEnabled),
            .notifyInfo(LuckgramHiddenChats.Strings.notifyInfo)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramHiddenChats.Strings.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
