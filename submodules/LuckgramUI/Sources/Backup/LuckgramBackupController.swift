import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AccountUtils
import OverlayStatusController
import LuckgramAccountsStore

/// Luckgram 32 backup strings; same texts as Android `LuckgramBackup`.
public enum LuckgramBackupStrings {
    public static var selectHeader: String { LuckgramStrings.pick("选择要备份的账号", "Accounts to back up") }
    public static var info: String { LuckgramStrings.pick("备份里只有登录信息和备注名，不包含消息、联系人或媒体。用你设置的密码在本机加密，iPhone 和 Android 通用。", "The backup holds only the logins and the local names, no messages, contacts or media. It is encrypted on this device with your password and works on both iPhone and Android.") }
    public static var warning: String { LuckgramStrings.pick("这份备份等于你账号的钥匙。任何人拿到备份和密码就能登录你的账号。", "This backup is the key to your accounts. Anyone with the backup and the password can log in to them.") }
    public static var passwordTitle: String { LuckgramStrings.pick("设置备份密码", "Set a backup password") }
    public static var passwordHint: String { LuckgramStrings.pick("密码（至少 8 位）", "Password (at least 8 characters)") }
    public static var passwordRepeatHint: String { LuckgramStrings.pick("再次输入密码", "Repeat password") }
    public static var passwordTooShort: String { LuckgramStrings.pick("密码至少 8 位", "The password must have at least 8 characters") }
    public static var passwordMismatch: String { LuckgramStrings.pick("两次输入的密码不一致", "The passwords don't match") }
    public static var enterPasswordTitle: String { LuckgramStrings.pick("输入备份密码", "Enter the backup password") }
    public static var wrongPassword: String { LuckgramStrings.pick("密码不正确", "Incorrect password") }
    public static func wait(_ seconds: Int) -> String { LuckgramStrings.pick("请 \(seconds) 秒后再试", "Try again in \(seconds) s") }
    public static var notBackup: String { LuckgramStrings.pick("云备份已损坏或来自更新版本的 Luckgram", "The cloud backup is damaged or was made by a newer Luckgram") }
    public static var chooseAccounts: String { LuckgramStrings.pick("选择要恢复的账号", "Accounts to restore") }
    public static var alreadyLoggedIn: String { LuckgramStrings.pick("已登录", "Already logged in") }
    public static var restoreButton: String { LuckgramStrings.pick("恢复", "Restore") }
    public static var selectAtLeastOne: String { LuckgramStrings.pick("请至少选择一个账号", "Select at least one account") }
    public static var noRoom: String { LuckgramStrings.pick("已达到账号上限，无法恢复更多账号", "The account limit is reached; no more accounts can be restored") }
    public static func result(restored: Int, skipped: Int, failed: Int) -> String {
        var text = LuckgramStrings.pick("已恢复 \(restored) 个账号", "\(restored) account(s) restored")
        if skipped > 0 {
            text += LuckgramStrings.pick("，\(skipped) 个已登录的账号已跳过", ", \(skipped) already logged in skipped")
        }
        if failed > 0 {
            text += LuckgramStrings.pick("，\(failed) 个账号恢复失败（会话可能已在其他设备上被终止）", ", \(failed) failed (the session may have been terminated on another device)")
        }
        return text
    }
    public static func accountLabel(userId: Int64, name: String) -> String {
        return name.isEmpty ? LuckgramStrings.pick("账号 \(userId)", "Account \(userId)") : "\(name) · \(userId)"
    }
}

// MARK: - Password prompts (secure text entry)

private func presentNewPasswordAlert(sharedContext: SharedAccountContext, completion: @escaping (String) -> Void) {
    let message = LuckgramBackupStrings.warning + "\n\n" + LuckgramCloudBackupStrings.warning
    let alert = UIAlertController(title: LuckgramBackupStrings.passwordTitle, message: message, preferredStyle: .alert)
    alert.addTextField { field in
        field.isSecureTextEntry = true
        field.placeholder = LuckgramBackupStrings.passwordHint
    }
    alert.addTextField { field in
        field.isSecureTextEntry = true
        field.placeholder = LuckgramBackupStrings.passwordRepeatHint
    }
    alert.addAction(UIAlertAction(title: LuckgramStrings.cancel, style: .cancel))
    alert.addAction(UIAlertAction(title: LuckgramCloudBackupStrings.upload, style: .default, handler: { [weak alert] _ in
        let first = alert?.textFields?.first?.text ?? ""
        let second = alert?.textFields?.last?.text ?? ""
        if first.count < LuckgramBackupFormat.minPasswordLength {
            presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.passwordTooShort)
        } else if first != second {
            presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.passwordMismatch)
        } else {
            completion(first)
        }
    }))
    sharedContext.applicationBindings.presentNativeController(alert)
}

private func presentPasswordAlert(sharedContext: SharedAccountContext, completion: @escaping (String) -> Void) {
    let alert = UIAlertController(title: LuckgramBackupStrings.enterPasswordTitle, message: nil, preferredStyle: .alert)
    alert.addTextField { field in
        field.isSecureTextEntry = true
        field.placeholder = LuckgramBackupStrings.passwordHint
    }
    alert.addAction(UIAlertAction(title: LuckgramStrings.cancel, style: .cancel))
    alert.addAction(UIAlertAction(title: LuckgramStrings.ok, style: .default, handler: { [weak alert] _ in
        let password = alert?.textFields?.first?.text ?? ""
        if !password.isEmpty {
            completion(password)
        }
    }))
    sharedContext.applicationBindings.presentNativeController(alert)
}

private func presentMessage(sharedContext: SharedAccountContext, _ text: String) {
    let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: LuckgramStrings.ok, style: .default))
    sharedContext.applicationBindings.presentNativeController(alert)
}

// MARK: - Restore flow (cloud backup page and login screen)

/// Wrong-password back-off for the whole process: 1, 2, 4… seconds between attempts.
private final class LuckgramBackupThrottle {
    static var failedAttempts = 0
    static var nextAttemptAt: Double = 0
}

private func askPasswordAndDecrypt(sharedContext: SharedAccountContext, fileData: Data, push: @escaping (ViewController) -> Void) {
    presentPasswordAlert(sharedContext: sharedContext, completion: { password in
        let wait = LuckgramBackupThrottle.nextAttemptAt - CFAbsoluteTimeGetCurrent()
        if wait > 0 {
            presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.wait(Int(wait.rounded(.up))))
            return
        }
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        // A spinner while PBKDF2 runs (600 000 iterations take about a second).
        let progress = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
        sharedContext.mainWindow?.present(progress, on: .root)
        Queue.concurrentDefaultQueue().async {
            let result: Result<[LuckgramBackupFormat.Account], LuckgramBackupFormat.DecodeError>
            do {
                result = .success(try LuckgramBackupFormat.decrypt(fileData: fileData, password: password))
            } catch let error as LuckgramBackupFormat.DecodeError {
                result = .failure(error)
            } catch {
                result = .failure(.format)
            }
            Queue.mainQueue().async {
                progress.dismiss()
                switch result {
                case let .success(accounts):
                    LuckgramBackupThrottle.failedAttempts = 0
                    LuckgramBackupThrottle.nextAttemptAt = 0
                    push(luckgramBackupRestoreController(sharedContext: sharedContext, accounts: accounts))
                case .failure(.wrongPassword):
                    LuckgramBackupThrottle.failedAttempts += 1
                    LuckgramBackupThrottle.nextAttemptAt = CFAbsoluteTimeGetCurrent() + Double(1 << min(LuckgramBackupThrottle.failedAttempts - 1, 10))
                    presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.wrongPassword)
                case .failure(.format):
                    presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.notBackup)
                }
            }
        }
    })
}

// MARK: - Choose accounts to restore

private final class LuckgramRestoreArguments {
    let toggle: (Int) -> Void
    let restore: () -> Void

    init(toggle: @escaping (Int) -> Void, restore: @escaping () -> Void) {
        self.toggle = toggle
        self.restore = restore
    }
}

private enum LuckgramRestoreEntry: ItemListNodeEntry {
    case header(String)
    case account(index: Int, title: String, checked: Bool, enabled: Bool)
    case restore(String)

    var section: ItemListSectionId {
        switch self {
        case .header, .account:
            return 0
        case .restore:
            return 1
        }
    }

    var stableId: Int {
        switch self {
        case .header:
            return 0
        case let .account(index, _, _, _):
            return 10 + index
        case .restore:
            return 100000
        }
    }

    static func <(lhs: LuckgramRestoreEntry, rhs: LuckgramRestoreEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: LuckgramRestoreEntry, rhs: LuckgramRestoreEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a), .header(b)):
            return a == b
        case let (.account(a1, a2, a3, a4), .account(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.restore(a), .restore(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramRestoreArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .account(index, title, checked, enabled):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                if enabled {
                    arguments.toggle(index)
                }
            })
        case let .restore(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.restore()
            })
        }
    }
}

private func luckgramBackupRestoreController(sharedContext: SharedAccountContext, accounts: [LuckgramBackupFormat.Account]) -> ViewController {
    var accounts = accounts
    let selected = ValuePromise<Set<Int>>(Set(), ignoreRepeated: true)
    var selectedValue = Set<Int>()
    var loggedInValue = Set<Int64>()
    var restoring = false
    var dismissImpl: (() -> Void)?

    let loggedIn = LuckgramBackup.loggedInUserIds(accountManager: sharedContext.accountManager)
    let _ = (loggedIn |> take(1) |> deliverOnMainQueue).start(next: { ids in
        loggedInValue = ids
        selectedValue = Set(accounts.indices.filter { !ids.contains(accounts[$0].userId) })
        selected.set(selectedValue)
    })

    let arguments = LuckgramRestoreArguments(toggle: { index in
        if selectedValue.contains(index) {
            selectedValue.remove(index)
        } else {
            selectedValue.insert(index)
        }
        selected.set(selectedValue)
    }, restore: {
        if restoring {
            return
        }
        let chosen = accounts.indices.filter { selectedValue.contains($0) && !loggedInValue.contains(accounts[$0].userId) }.map { accounts[$0] }
        let alreadyLoggedIn = accounts.filter { loggedInValue.contains($0.userId) }.count
        if chosen.isEmpty {
            presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.selectAtLeastOne)
            return
        }
        restoring = true
        let _ = (LuckgramBackup.restore(accountManager: sharedContext.accountManager, accounts: chosen)
        |> deliverOnMainQueue).start(next: { result in
            for i in accounts.indices {
                accounts[i].wipe()
            }
            let text = result.noRoom > 0 && result.restored == 0 ? LuckgramBackupStrings.noRoom : LuckgramBackupStrings.result(restored: result.restored, skipped: result.skipped + alreadyLoggedIn, failed: result.noRoom)
            presentMessage(sharedContext: sharedContext, text)
            dismissImpl?()
        })
    })

    let signal = combineLatest(queue: .mainQueue(), sharedContext.presentationData, selected.get(), loggedIn)
    |> map { presentationData, selected, loggedIn -> (ItemListControllerState, (ItemListNodeState, Any)) in
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        var entries: [LuckgramRestoreEntry] = [.header(LuckgramBackupStrings.chooseAccounts.uppercased())]
        for (index, account) in accounts.enumerated() {
            let isLoggedIn = loggedIn.contains(account.userId)
            var title = LuckgramBackupStrings.accountLabel(userId: account.userId, name: account.name)
            if isLoggedIn {
                title += " · " + LuckgramBackupStrings.alreadyLoggedIn
            }
            entries.append(.account(index: index, title: title, checked: !isLoggedIn && selected.contains(index), enabled: !isLoggedIn))
        }
        entries.append(.restore(LuckgramBackupStrings.restoreButton))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramCloudBackupStrings.restore), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        Queue.mainQueue().async {
            if !restoring {
                for i in accounts.indices {
                    accounts[i].wipe()
                }
            }
        }
    }

    let presentationData = sharedContext.currentPresentationData.with { $0 }
    let controller = ItemListController(presentationData: ItemListPresentationData(presentationData), updatedPresentationData: sharedContext.presentationData |> map(ItemListPresentationData.init(_:)), state: signal, tabBarItem: nil)
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}

// MARK: - Cloud backup (32)

/// "Restore from cloud": download the ciphertext, then password → choose accounts → restore.
/// `context` nil on the login screen: the device must already be linked (any account logged in).
public func luckgramStartCloudRestore(sharedContext: SharedAccountContext, context: AccountContext?, push: @escaping (ViewController) -> Void) {
    let presentationData = sharedContext.currentPresentationData.with { $0 }
    LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
    let progress = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
    sharedContext.mainWindow?.present(progress, on: .root)
    let _ = LuckgramCloudBackup.download(context: context).start(next: { data in
        progress.dismiss()
        guard let data else {
            presentMessage(sharedContext: sharedContext, LuckgramCloudBackupStrings.noBackup)
            return
        }
        askPasswordAndDecrypt(sharedContext: sharedContext, fileData: data, push: push)
    }, error: { error in
        progress.dismiss()
        presentMessage(sharedContext: sharedContext, context == nil && error.code == "not_linked" ? LuckgramCloudBackupStrings.needAccount : LuckgramCloudBackupStrings.error(error))
    })
}

private func presentRememberChoice(sharedContext: SharedAccountContext, completion: @escaping (Bool) -> Void) {
    let alert = UIAlertController(title: nil, message: LuckgramCloudBackupStrings.remember + "\n\n" + LuckgramCloudBackupStrings.autoInfo, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: LuckgramCloudBackupStrings.rememberNo, style: .cancel, handler: { _ in
        completion(false)
    }))
    alert.addAction(UIAlertAction(title: LuckgramCloudBackupStrings.rememberYes, style: .default, handler: { _ in
        completion(true)
    }))
    sharedContext.applicationBindings.presentNativeController(alert)
}

private enum LuckgramCloudAction {
    case pro
    case upload
    case restore
    case delete
    case auto(Bool)
}

private enum LuckgramCloudState: Equatable {
    case loading
    case empty
    case ready(LuckgramCloudBackupLogic.Meta)
    case error(String)
}

private final class LuckgramCloudBackupArguments {
    let toggle: (Int64) -> Void
    let action: (LuckgramCloudAction) -> Void

    init(toggle: @escaping (Int64) -> Void, action: @escaping (LuckgramCloudAction) -> Void) {
        self.toggle = toggle
        self.action = action
    }
}

private enum LuckgramCloudBackupEntry: ItemListNodeEntry {
    case header(String)
    case account(index: Int, accountId: Int64, title: String, checked: Bool)
    case info(String)
    case pro(String, String)
    case upload(String)
    case restore(String)
    case delete(String)
    case status(String)
    case auto(String, Bool)
    case autoInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .header, .account, .info:
            return 0
        case .pro, .upload, .restore, .delete, .status:
            return 1
        case .auto, .autoInfo:
            return 2
        }
    }

    var sortIndex: Int {
        switch self {
        case .header:
            return 0
        case let .account(index, _, _, _):
            return 10 + index
        case .info:
            return 999
        case .pro:
            return 1000
        case .upload:
            return 1001
        case .restore:
            return 1002
        case .delete:
            return 1003
        case .status:
            return 1004
        case .auto:
            return 2000
        case .autoInfo:
            return 2001
        }
    }

    var stableId: Int {
        return self.sortIndex
    }

    static func <(lhs: LuckgramCloudBackupEntry, rhs: LuckgramCloudBackupEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    static func ==(lhs: LuckgramCloudBackupEntry, rhs: LuckgramCloudBackupEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a), .header(b)), let (.info(a), .info(b)), let (.upload(a), .upload(b)), let (.restore(a), .restore(b)),
             let (.delete(a), .delete(b)), let (.status(a), .status(b)), let (.autoInfo(a), .autoInfo(b)):
            return a == b
        case let (.pro(a1, a2), .pro(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.auto(a1, a2), .auto(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.account(a1, a2, a3, a4), .account(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramCloudBackupArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .account(_, accountId, title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.toggle(accountId)
            })
        case let .info(text), let .status(text), let .autoInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .pro(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.action(.pro)
            })
        case let .upload(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.action(.upload)
            })
        case let .restore(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.action(.restore)
            })
        case let .delete(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.action(.delete)
            })
        case let .auto(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.action(.auto(value))
            })
        }
    }
}

/// Luckgram Features → Luckgram Pro → Cloud backup (Pro). Pick accounts, back up (encrypted on
/// this device), restore, delete, weekly backup. No file export / import. Same layout and texts
/// as Android `CloudBackupActivity`.
public func luckgramCloudBackupController(context: AccountContext) -> ViewController {
    let sharedContext = context.sharedContext
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var uploadImpl: (([AccountRecordId]?, String, Bool) -> Void)?
    let cloudState = ValuePromise<LuckgramCloudState>(.loading, ignoreRepeated: true)
    let autoChanged = ValuePromise<Double>(0, ignoreRepeated: true)
    var deselected = Set<Int64>()
    let deselectedPromise = ValuePromise<Set<Int64>>(Set(), ignoreRepeated: true)
    var accountIdsValue: [Int64] = []

    let accounts: Signal<[(Int64, String)], NoError> = activeAccountsAndPeers(context: context, includePrimary: true)
    |> map { _, accounts -> [(Int64, String)] in
        return accounts.map { ($0.0.account.id.int64, $0.1.compactDisplayTitle) }
    }

    let arguments = LuckgramCloudBackupArguments(toggle: { accountId in
        if deselected.contains(accountId) {
            deselected.remove(accountId)
        } else {
            deselected.insert(accountId)
        }
        deselectedPromise.set(deselected)
    }, action: { action in
        switch action {
        case .pro:
            presentImpl?(luckgramProUpgradeController(context: context, reason: LuckgramCloudBackupStrings.proOnly, openPro: {
                pushImpl?(luckgramProController(context: context))
            }))
        case .upload:
            let recordIds = accountIdsValue.filter { !deselected.contains($0) }.map { AccountRecordId(rawValue: $0) }
            if recordIds.isEmpty {
                presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.selectAtLeastOne)
                return
            }
            presentNewPasswordAlert(sharedContext: sharedContext, completion: { password in
                presentRememberChoice(sharedContext: sharedContext, completion: { remember in
                    uploadImpl?(recordIds, password, remember)
                })
            })
        case .restore:
            luckgramStartCloudRestore(sharedContext: sharedContext, context: context, push: { c in
                pushImpl?(c)
            })
        case .delete:
            let alert = UIAlertController(title: LuckgramCloudBackupStrings.delete, message: LuckgramCloudBackupStrings.deleteConfirm, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: LuckgramStrings.cancel, style: .cancel))
            alert.addAction(UIAlertAction(title: LuckgramCloudBackupStrings.delete, style: .destructive, handler: { _ in
                let _ = LuckgramCloudBackup.delete(context: context).start(next: { _ in
                    cloudState.set(.empty)
                    presentMessage(sharedContext: sharedContext, LuckgramCloudBackupStrings.deleted)
                }, error: { error in
                    presentMessage(sharedContext: sharedContext, LuckgramCloudBackupStrings.error(error))
                })
            }))
            sharedContext.applicationBindings.presentNativeController(alert)
        case let .auto(value):
            if value {
                // Turning it on needs the password remembered; back up every account right away with it.
                presentNewPasswordAlert(sharedContext: sharedContext, completion: { password in
                    uploadImpl?(nil, password, true)
                })
            } else {
                LuckgramCloudBackup.setAuto(password: nil)
            }
            autoChanged.set(Date().timeIntervalSince1970)
        }
    })

    /// `recordIds` nil: every logged-in account (weekly backup).
    uploadImpl = { recordIds, password, remember in
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        let progress = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
        sharedContext.mainWindow?.present(progress, on: .root)
        let _ = LuckgramCloudBackup.upload(accountManager: sharedContext.accountManager, context: context, recordIds: recordIds, password: password).start(next: { meta in
            progress.dismiss()
            if remember {
                LuckgramCloudBackup.setAuto(password: password)
            } else if LuckgramCloudBackup.isAutoEnabled {
                LuckgramCloudBackup.setAuto(password: nil)
            }
            LuckgramCloudBackup.markUploaded()
            cloudState.set(.ready(meta))
            autoChanged.set(Date().timeIntervalSince1970)
            presentMessage(sharedContext: sharedContext, LuckgramCloudBackupStrings.uploaded)
        }, error: { error in
            progress.dismiss()
            autoChanged.set(Date().timeIntervalSince1970)
            if error.code == "not_pro" {
                presentImpl?(luckgramProUpgradeController(context: context, reason: LuckgramCloudBackupStrings.error(error), openPro: {
                    pushImpl?(luckgramProController(context: context))
                }))
            } else {
                presentMessage(sharedContext: sharedContext, LuckgramCloudBackupStrings.error(error))
            }
        })
    }

    if luckgramIsPro() {
        let _ = LuckgramCloudBackup.fetch(context: context).start(next: { meta in
            cloudState.set(meta.map { LuckgramCloudState.ready($0) } ?? LuckgramCloudState.empty)
        }, error: { error in
            cloudState.set(.error(LuckgramCloudBackupStrings.error(error)))
        })
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, accounts, deselectedPromise.get(), cloudState.get(), autoChanged.get())
    |> map { presentationData, accounts, deselected, cloud, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        accountIdsValue = accounts.map(\.0)
        var entries: [LuckgramCloudBackupEntry] = []
        if !luckgramIsPro() {
            entries.append(.header(LuckgramCloudBackupStrings.header.uppercased()))
            entries.append(.pro(LuckgramCloudBackupStrings.upload, "Pro"))
            entries.append(.status(LuckgramCloudBackupStrings.proOnly + "\n\n" + LuckgramCloudBackupStrings.warning))
        } else {
            entries.append(.header(LuckgramBackupStrings.selectHeader.uppercased()))
            for (index, account) in accounts.enumerated() {
                entries.append(.account(index: index, accountId: account.0, title: account.1, checked: !deselected.contains(account.0)))
            }
            entries.append(.info(LuckgramBackupStrings.info))
            entries.append(.upload(LuckgramCloudBackupStrings.upload))
            let status: String
            switch cloud {
            case .loading:
                status = LuckgramCloudBackupStrings.loading
            case .empty:
                status = LuckgramCloudBackupStrings.noBackup
            case let .ready(meta):
                status = LuckgramCloudBackupStrings.status(meta)
                entries.append(.restore(LuckgramCloudBackupStrings.restore))
                entries.append(.delete(LuckgramCloudBackupStrings.delete))
            case let .error(text):
                status = text
            }
            entries.append(.status(status + "\n\n" + LuckgramBackupStrings.warning + "\n" + LuckgramCloudBackupStrings.warning))
            entries.append(.auto(LuckgramCloudBackupStrings.auto, LuckgramCloudBackup.isAutoEnabled))
            entries.append(.autoInfo(LuckgramCloudBackupStrings.autoInfo))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramCloudBackupStrings.header), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
