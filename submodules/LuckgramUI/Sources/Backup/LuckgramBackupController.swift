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
import LegacyMediaPickerUI
import OverlayStatusController
import LuckgramAccountsStore

/// Luckgram 10 strings; same texts as Android `LuckgramBackup`.
public enum LuckgramBackupStrings {
    public static var title: String { LuckgramStrings.pick("账号备份", "Account backup") }
    public static var selectHeader: String { LuckgramStrings.pick("选择要导出的账号", "Accounts to export") }
    public static var export: String { LuckgramStrings.pick("导出为文件", "Export to file") }
    public static var restore: String { LuckgramStrings.pick("从备份恢复", "Restore from backup") }
    public static var info: String { LuckgramStrings.pick("备份文件里只有登录信息和备注名，不包含消息、联系人或媒体。文件用你设置的密码加密，iPhone 和 Android 通用。", "The file holds only the login and the local names, no messages, contacts or media. It is encrypted with your password and works on both iPhone and Android.") }
    public static var warning: String { LuckgramStrings.pick("这个文件等于你账号的钥匙。任何人拿到文件和密码就能登录你的账号。不要发给别人，不要存到不信任的地方。", "This file is the key to your accounts. Anyone with the file and the password can log in to them. Don't send it to anyone and don't keep it anywhere you don't trust.") }
    public static var passwordTitle: String { LuckgramStrings.pick("设置备份密码", "Set a backup password") }
    public static var passwordHint: String { LuckgramStrings.pick("密码（至少 8 位）", "Password (at least 8 characters)") }
    public static var passwordRepeatHint: String { LuckgramStrings.pick("再次输入密码", "Repeat password") }
    public static var passwordTooShort: String { LuckgramStrings.pick("密码至少 8 位", "The password must have at least 8 characters") }
    public static var passwordMismatch: String { LuckgramStrings.pick("两次输入的密码不一致", "The passwords don't match") }
    public static var enterPasswordTitle: String { LuckgramStrings.pick("输入备份密码", "Enter the backup password") }
    public static var wrongPassword: String { LuckgramStrings.pick("密码不正确", "Incorrect password") }
    public static func wait(_ seconds: Int) -> String { LuckgramStrings.pick("请 \(seconds) 秒后再试", "Try again in \(seconds) s") }
    public static var notBackup: String { LuckgramStrings.pick("这不是 Luckgram 备份文件，或文件已损坏", "This isn't a Luckgram backup file, or the file is damaged") }
    public static var chooseAccounts: String { LuckgramStrings.pick("选择要恢复的账号", "Accounts to restore") }
    public static var alreadyLoggedIn: String { LuckgramStrings.pick("已登录", "Already logged in") }
    public static var restoreButton: String { LuckgramStrings.pick("恢复", "Restore") }
    public static var selectAtLeastOne: String { LuckgramStrings.pick("请至少选择一个账号", "Select at least one account") }
    public static var exportFailed: String { LuckgramStrings.pick("导出失败", "Export failed") }
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
    let alert = UIAlertController(title: LuckgramBackupStrings.passwordTitle, message: LuckgramBackupStrings.warning, preferredStyle: .alert)
    alert.addTextField { field in
        field.isSecureTextEntry = true
        field.placeholder = LuckgramBackupStrings.passwordHint
    }
    alert.addTextField { field in
        field.isSecureTextEntry = true
        field.placeholder = LuckgramBackupStrings.passwordRepeatHint
    }
    alert.addAction(UIAlertAction(title: LuckgramStrings.cancel, style: .cancel))
    alert.addAction(UIAlertAction(title: LuckgramBackupStrings.export, style: .default, handler: { [weak alert] _ in
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

// MARK: - Restore flow (settings page and login screen)

/// Wrong-password back-off for the whole process: 1, 2, 4… seconds between attempts.
private final class LuckgramBackupThrottle {
    static var failedAttempts = 0
    static var nextAttemptAt: Double = 0
}

/// Pick a file → password → choose accounts → restore. `present` shows a controller over the
/// current screen; `push` opens the account list.
public func luckgramStartBackupRestore(sharedContext: SharedAccountContext, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
    let presentationData = sharedContext.currentPresentationData.with { $0 }
    LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
    let picker = legacyICloudFilePicker(theme: presentationData.theme, mode: .import, documentTypes: ["public.item"], completion: { urls in
        guard let url = urls.first else {
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        if accessing {
            url.stopAccessingSecurityScopedResource()
        }
        guard let data, data.count < 1024 * 1024 else {
            presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.notBackup)
            return
        }
        askPasswordAndDecrypt(sharedContext: sharedContext, fileData: data, push: push)
    })
    present(picker)
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
            let text = result.noRoom > 0 && result.restored == 0 ? LuckgramBackupStrings.noRoom : LuckgramBackupStrings.result(restored: result.restored, skipped: result.skipped, failed: result.noRoom)
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
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramBackupStrings.restore), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
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

// MARK: - Luckgram Features → Account backup

private final class LuckgramBackupArguments {
    let toggle: (Int64) -> Void
    let export: () -> Void
    let restore: () -> Void

    init(toggle: @escaping (Int64) -> Void, export: @escaping () -> Void, restore: @escaping () -> Void) {
        self.toggle = toggle
        self.export = export
        self.restore = restore
    }
}

private enum LuckgramBackupEntry: ItemListNodeEntry {
    case header(String)
    case account(index: Int, accountId: Int64, title: String, checked: Bool)
    case export(String)
    case warning(String)
    case restore(String)
    case info(String)

    var section: ItemListSectionId {
        switch self {
        case .header, .account:
            return 0
        case .export, .warning:
            return 1
        case .restore, .info:
            return 2
        }
    }

    var sortIndex: Int {
        switch self {
        case .header:
            return 0
        case let .account(index, _, _, _):
            return 10 + index
        case .export:
            return 1000
        case .warning:
            return 1001
        case .restore:
            return 2000
        case .info:
            return 2001
        }
    }

    var stableId: Int {
        return self.sortIndex
    }

    static func <(lhs: LuckgramBackupEntry, rhs: LuckgramBackupEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    static func ==(lhs: LuckgramBackupEntry, rhs: LuckgramBackupEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a), .header(b)), let (.export(a), .export(b)), let (.warning(a), .warning(b)), let (.restore(a), .restore(b)), let (.info(a), .info(b)):
            return a == b
        case let (.account(a1, a2, a3, a4), .account(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramBackupArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .account(_, accountId, title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.toggle(accountId)
            })
        case let .export(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.export()
            })
        case let .warning(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown("**\(text)**"), sectionId: self.section)
        case let .restore(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.restore()
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

public func luckgramBackupController(context: AccountContext) -> ViewController {
    let sharedContext = context.sharedContext
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var deselected = Set<Int64>()
    let deselectedPromise = ValuePromise<Set<Int64>>(Set(), ignoreRepeated: true)
    var accountIdsValue: [Int64] = []

    let accounts: Signal<[(Int64, String)], NoError> = activeAccountsAndPeers(context: context, includePrimary: true)
    |> map { _, accounts -> [(Int64, String)] in
        return accounts.map { ($0.0.account.id.int64, $0.1.compactDisplayTitle) }
    }

    let arguments = LuckgramBackupArguments(toggle: { accountId in
        if deselected.contains(accountId) {
            deselected.remove(accountId)
        } else {
            deselected.insert(accountId)
        }
        deselectedPromise.set(deselected)
    }, export: {
        let recordIds = accountIdsValue.filter { !deselected.contains($0) }.map { AccountRecordId(rawValue: $0) }
        if recordIds.isEmpty {
            presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.selectAtLeastOne)
            return
        }
        presentNewPasswordAlert(sharedContext: sharedContext, completion: { password in
            let _ = (LuckgramBackup.collect(accountManager: sharedContext.accountManager, recordIds: recordIds)
            |> deliverOn(Queue.concurrentDefaultQueue())
            |> map { items -> URL? in
                var items = items
                defer {
                    for i in items.indices {
                        items[i].wipe()
                    }
                }
                guard !items.isEmpty, let data = try? LuckgramBackupFormat.encrypt(accounts: items, password: password) else {
                    return nil
                }
                let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("luckgram-backup", isDirectory: true)
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd-HHmm"
                let url = directory.appendingPathComponent("luckgram-\(formatter.string(from: Date())).\(LuckgramBackupFormat.fileExtension)")
                do {
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    return url
                } catch {
                    return nil
                }
            }
            |> deliverOnMainQueue).start(next: { url in
                guard let url else {
                    presentMessage(sharedContext: sharedContext, LuckgramBackupStrings.exportFailed)
                    return
                }
                let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let window = sharedContext.mainWindow?.viewController?.view.window {
                    activityController.popoverPresentationController?.sourceView = window
                    activityController.popoverPresentationController?.sourceRect = CGRect(origin: CGPoint(x: window.bounds.width / 2.0, y: window.bounds.size.height - 1.0), size: CGSize(width: 1.0, height: 1.0))
                }
                sharedContext.applicationBindings.presentNativeController(activityController)
            })
        })
    }, restore: {
        luckgramStartBackupRestore(sharedContext: sharedContext, present: { c in
            presentImpl?(c)
        }, push: { c in
            pushImpl?(c)
        })
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, accounts, deselectedPromise.get())
    |> map { presentationData, accounts, deselected -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        accountIdsValue = accounts.map(\.0)
        var entries: [LuckgramBackupEntry] = [.header(LuckgramBackupStrings.selectHeader.uppercased())]
        for (index, account) in accounts.enumerated() {
            entries.append(.account(index: index, accountId: account.0, title: account.1, checked: !deselected.contains(account.0)))
        }
        entries.append(.export(LuckgramBackupStrings.export))
        entries.append(.warning(LuckgramBackupStrings.warning))
        entries.append(.restore(LuckgramBackupStrings.restore))
        entries.append(.info(LuckgramBackupStrings.info))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramBackupStrings.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
