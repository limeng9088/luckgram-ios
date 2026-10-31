import Foundation
import UIKit
import CryptoKit
import Security
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AccountUtils
import PasscodeCore
import LuckgramAccountsStore

/// Luckgram 11 (double space): a second passcode. Unlocking with it shows only the accounts the
/// user picked; the main passcode shows everything. The second passcode is kept as a salted
/// SHA-256 hash in the Keychain (same construction as Android: SHA-256(salt ‖ code ‖ salt)).
public enum LuckgramDoubleBottom {
    public static let featureKey = "double_bottom"

    private static let hashAccount = "double_bottom.hash"
    private static let saltAccount = "double_bottom.salt"

    /// Set by SharedAccountContextImpl: opens Telegram's Passcode Lock setup (SettingsUI).
    public static var openPasscodeSetup: ((AccountContext, @escaping (ViewController) -> Void) -> Void)?

    // MARK: - Strings (same as Android)

    public static var title: String { LuckgramStrings.pick("双重空间", "Double space") }
    public static var descriptionText: String { LuckgramStrings.pick("用第二个密码解锁时只显示选定的账号", "A second passcode that shows only the accounts you pick") }
    static var needPasscode: String { LuckgramStrings.pick("请先在「隐私与安全 → 密码锁」里开启应用密码锁。", "Turn on Passcode Lock in Privacy and Security first.") }
    static var openPasscode: String { LuckgramStrings.pick("开启密码锁", "Turn on Passcode Lock") }
    static var setPasscode: String { LuckgramStrings.pick("设置第二密码", "Set second passcode") }
    static var changePasscode: String { LuckgramStrings.pick("修改第二密码", "Change second passcode") }
    static var enterSecond: String { LuckgramStrings.pick("输入第二密码", "Enter the second passcode") }
    static var repeatSecond: String { LuckgramStrings.pick("再次输入第二密码", "Repeat the second passcode") }
    static var sameAsMain: String { LuckgramStrings.pick("第二密码不能与主密码相同", "The second passcode must differ from the main passcode") }
    static var mismatch: String { LuckgramStrings.pick("两次输入的密码不一致", "The passcodes don't match") }
    static func digitsRule(_ count: Int) -> String { LuckgramStrings.pick("请输入 \(count) 位数字", "Enter \(count) digits") }
    static var visibleHeader: String { LuckgramStrings.pick("第二密码下可见的账号", "Accounts visible with the second passcode") }
    static var visibleInfo: String { LuckgramStrings.pick("用第二密码解锁时，只有这些账号会出现在账号列表、快速切换和通知中。至少选一个。", "With the second passcode, only these accounts appear in the account list, the account switcher and notifications. Pick at least one.") }
    static var atLeastOne: String { LuckgramStrings.pick("至少选择一个账号", "Pick at least one account") }
    static var turnOff: String { LuckgramStrings.pick("关闭双重空间", "Turn off double space") }
    static var enterMain: String { LuckgramStrings.pick("输入主密码", "Enter the main passcode") }
    static var wrongMain: String { LuckgramStrings.pick("主密码不正确", "Incorrect main passcode") }
    static var saved: String { LuckgramStrings.pick("第二密码已设置", "Second passcode set") }

    // MARK: - State

    public static var hasSecondPasscode: Bool {
        return !(LuckgramKeychain.get(account: hashAccount)?.isEmpty ?? true)
    }

    /// Installs the passcode-screen hook. Called once at app start.
    public static func install() {
        LuckgramDoubleBottomState.shared.secondPasscodeCheck = { code in
            guard LuckgramSettings.shared.isEnabled(featureKey), !LuckgramDoubleBottomState.shared.visibleAccountIds.isEmpty else {
                return false
            }
            return checkSecondPasscode(code)
        }
    }

    static func setSecondPasscode(_ code: String) {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        precondition(status == errSecSuccess)
        LuckgramKeychain.set(account: saltAccount, value: hex(salt))
        LuckgramKeychain.set(account: hashAccount, value: hash(code, salt: salt))
    }

    static func checkSecondPasscode(_ code: String) -> Bool {
        guard let stored = LuckgramKeychain.get(account: hashAccount), !stored.isEmpty,
              let saltHex = LuckgramKeychain.get(account: saltAccount), let salt = data(hex: saltHex), salt.count == 16 else {
            return false
        }
        return stored == hash(code, salt: salt)
    }

    /// Switches the feature off and forgets the second passcode (after the main passcode was entered).
    public static func turnOff() {
        LuckgramKeychain.delete(account: hashAccount)
        LuckgramKeychain.delete(account: saltAccount)
        LuckgramDoubleBottomState.shared.reset()
        LuckgramSettings.shared.setEnabled(featureKey, false)
    }

    private static func hash(_ code: String, salt: Data) -> String {
        var bytes = Data()
        bytes.append(salt)
        bytes.append(Data(code.utf8))
        bytes.append(salt)
        defer {
            bytes.resetBytes(in: 0 ..< bytes.count)
        }
        return hex(Data(SHA256.hash(data: bytes)))
    }

    private static func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else {
            return nil
        }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    // MARK: - Main passcode

    private static func reference(from challenge: PostboxAccessChallengeData) throws -> PasscodeCredentialReference? {
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

    private static func passcodeKind(_ challenge: PostboxAccessChallengeData) -> PasscodeKind? {
        switch challenge {
        case .none:
            return nil
        case let .numericalPassword(value):
            return value.count == 6 ? .digits6 : .digits4
        case .plaintextPassword:
            return .alphanumeric
        case let .secured(_, kind):
            return PasscodeKind(rawValue: kind.rawValue) ?? .alphanumeric
        }
    }

    /// Asks for the main passcode and verifies it with Telegram's credential store (a wrong code
    /// counts as a failed attempt there, like on the lock screen). `completion` gets the code.
    private static func requestMainPasscode(sharedContext: SharedAccountContext, challenge: PostboxAccessChallengeData, completion: @escaping (String) -> Void) {
        let kind = passcodeKind(challenge) ?? .alphanumeric
        let alert = UIAlertController(title: enterMain, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.keyboardType = kind == .alphanumeric ? .default : .numberPad
        }
        alert.addAction(UIAlertAction(title: LuckgramStrings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: LuckgramStrings.ok, style: .default, handler: { [weak alert] _ in
            let code = alert?.textFields?.first?.text ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let ok: Bool
                do {
                    let session = try PasscodeCredentialStore.shared.verify(code, reference: try reference(from: challenge), scope: .settings)
                    session.invalidate()
                    ok = true
                } catch {
                    ok = false
                }
                DispatchQueue.main.async {
                    if ok {
                        completion(code)
                    } else {
                        message(sharedContext: sharedContext, wrongMain)
                    }
                }
            }
        }))
        sharedContext.applicationBindings.presentNativeController(alert)
    }

    private static func requestSecondPasscode(sharedContext: SharedAccountContext, kind: PasscodeKind, mainCode: String, completion: @escaping () -> Void) {
        let alert = UIAlertController(title: setPasscode, message: nil, preferredStyle: .alert)
        for placeholder in [enterSecond, repeatSecond] {
            alert.addTextField { field in
                field.isSecureTextEntry = true
                field.placeholder = placeholder
                field.keyboardType = kind == .alphanumeric ? .default : .numberPad
            }
        }
        alert.addAction(UIAlertAction(title: LuckgramStrings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: LuckgramStrings.ok, style: .default, handler: { [weak alert] _ in
            let first = alert?.textFields?.first?.text ?? ""
            let second = alert?.textFields?.last?.text ?? ""
            let digits: Int?
            switch kind {
            case .digits4:
                digits = 4
            case .digits6:
                digits = 6
            case .alphanumeric:
                digits = nil
            }
            if let digits, first.count != digits || !first.allSatisfy({ $0.isNumber }) {
                message(sharedContext: sharedContext, digitsRule(digits))
            } else if first.isEmpty {
                message(sharedContext: sharedContext, enterSecond)
            } else if first != second {
                message(sharedContext: sharedContext, mismatch)
            } else if first == mainCode || kind.normalize(first) == kind.normalize(mainCode) {
                message(sharedContext: sharedContext, sameAsMain)
            } else {
                setSecondPasscode(first)
                completion()
            }
        }))
        sharedContext.applicationBindings.presentNativeController(alert)
    }

    private static func message(sharedContext: SharedAccountContext, _ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LuckgramStrings.ok, style: .default))
        sharedContext.applicationBindings.presentNativeController(alert)
    }

    private static func challenge(sharedContext: SharedAccountContext) -> Signal<PostboxAccessChallengeData, NoError> {
        return sharedContext.accountManager.transaction { transaction -> PostboxAccessChallengeData in
            return transaction.getAccessChallengeData()
        }
        |> deliverOnMainQueue
    }

    // MARK: - Feature switch hooks

    /// Switching on from Luckgram Features: needs Passcode Lock, a second passcode and visible accounts.
    public static func confirmEnable(context: AccountContext, present: @escaping (ViewController) -> Void, done: @escaping (Bool) -> Void) {
        let _ = (challenge(sharedContext: context.sharedContext) |> take(1)).start(next: { challenge in
            if case .none = challenge {
                message(sharedContext: context.sharedContext, needPasscode)
                done(false)
            } else if hasSecondPasscode && !LuckgramDoubleBottomState.shared.visibleAccountIds.isEmpty {
                done(true)
            } else {
                present(luckgramDoubleBottomController(context: context))
                done(false)
            }
        })
    }

    /// Switching off needs the main passcode.
    public static func confirmDisable(context: AccountContext, present: @escaping (ViewController) -> Void, done: @escaping (Bool) -> Void) {
        let _ = (challenge(sharedContext: context.sharedContext) |> take(1)).start(next: { challenge in
            if case .none = challenge {
                turnOff()
                done(true)
                return
            }
            requestMainPasscode(sharedContext: context.sharedContext, challenge: challenge, completion: { _ in
                turnOff()
                done(true)
            })
        })
    }

    // MARK: - Settings page

    private final class Arguments {
        let openPasscode: () -> Void
        let setPasscode: () -> Void
        let toggle: (Int64) -> Void
        let turnOff: () -> Void

        init(openPasscode: @escaping () -> Void, setPasscode: @escaping () -> Void, toggle: @escaping (Int64) -> Void, turnOff: @escaping () -> Void) {
            self.openPasscode = openPasscode
            self.setPasscode = setPasscode
            self.toggle = toggle
            self.turnOff = turnOff
        }
    }

    private enum Entry: ItemListNodeEntry {
        case openPasscode(String)
        case needPasscode(String)
        case setPasscode(String)
        case description(String)
        case visibleHeader(String)
        case account(index: Int, accountId: Int64, title: String, checked: Bool)
        case visibleInfo(String)
        case turnOff(String)

        var section: ItemListSectionId {
            switch self {
            case .openPasscode, .needPasscode, .setPasscode, .description:
                return 0
            case .visibleHeader, .account, .visibleInfo:
                return 1
            case .turnOff:
                return 2
            }
        }

        var sortIndex: Int {
            switch self {
            case .openPasscode:
                return 0
            case .needPasscode:
                return 1
            case .setPasscode:
                return 2
            case .description:
                return 3
            case .visibleHeader:
                return 100
            case let .account(index, _, _, _):
                return 101 + index
            case .visibleInfo:
                return 1000
            case .turnOff:
                return 2000
            }
        }

        var stableId: Int {
            return self.sortIndex
        }

        static func <(lhs: Entry, rhs: Entry) -> Bool {
            return lhs.sortIndex < rhs.sortIndex
        }

        static func ==(lhs: Entry, rhs: Entry) -> Bool {
            switch (lhs, rhs) {
            case let (.openPasscode(a), .openPasscode(b)), let (.needPasscode(a), .needPasscode(b)), let (.setPasscode(a), .setPasscode(b)), let (.description(a), .description(b)), let (.visibleHeader(a), .visibleHeader(b)), let (.visibleInfo(a), .visibleInfo(b)), let (.turnOff(a), .turnOff(b)):
                return a == b
            case let (.account(a1, a2, a3, a4), .account(b1, b2, b3, b4)):
                return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
            default:
                return false
            }
        }

        func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
            let arguments = arguments as! Arguments
            switch self {
            case let .openPasscode(text):
                return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                    arguments.openPasscode()
                })
            case let .needPasscode(text), let .description(text), let .visibleInfo(text):
                return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
            case let .setPasscode(text):
                return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                    arguments.setPasscode()
                })
            case let .visibleHeader(text):
                return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
            case let .account(_, accountId, title, checked):
                return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                    arguments.toggle(accountId)
                })
            case let .turnOff(text):
                return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                    arguments.turnOff()
                })
            }
        }
    }

    private static func entries(challenge: PostboxAccessChallengeData, accounts: [(Int64, String)], visible: [Int64], hasSecond: Bool) -> [Entry] {
        if case .none = challenge {
            return [.openPasscode(openPasscode), .needPasscode(needPasscode)]
        }
        var entries: [Entry] = []
        entries.append(.setPasscode(hasSecond ? changePasscode : setPasscode))
        entries.append(.description(descriptionText))
        entries.append(.visibleHeader(visibleHeader.uppercased()))
        for (index, account) in accounts.enumerated() {
            entries.append(.account(index: index, accountId: account.0, title: account.1, checked: visible.contains(account.0)))
        }
        entries.append(.visibleInfo(visibleInfo))
        if hasSecond {
            entries.append(.turnOff(turnOff))
        }
        return entries
    }

    /// The switch turns on once a second passcode and at least one visible account are set.
    private static func updateEnabled() {
        if hasSecondPasscode, !LuckgramDoubleBottomState.shared.visibleAccountIds.isEmpty, !LuckgramSettings.shared.isEnabled(featureKey) {
            LuckgramSettings.shared.setEnabled(featureKey, true)
        }
    }

    public static func controller(context: AccountContext) -> ViewController {
        let sharedContext = context.sharedContext
        var pushImpl: ((ViewController) -> Void)?
        var dismissImpl: (() -> Void)?
        let hasSecondPromise = ValuePromise<Bool>(hasSecondPasscode, ignoreRepeated: true)
        var challengeValue: PostboxAccessChallengeData = .none

        let arguments = Arguments(openPasscode: {
            openPasscodeSetup?(context, { c in pushImpl?(c) })
        }, setPasscode: {
            guard let kind = passcodeKind(challengeValue) else {
                return
            }
            requestMainPasscode(sharedContext: sharedContext, challenge: challengeValue, completion: { mainCode in
                requestSecondPasscode(sharedContext: sharedContext, kind: kind, mainCode: mainCode, completion: {
                    if LuckgramDoubleBottomState.shared.visibleAccountIds.isEmpty {
                        LuckgramDoubleBottomState.shared.setVisibleAccountIds([context.account.id.int64])
                    }
                    hasSecondPromise.set(hasSecondPasscode)
                    updateEnabled()
                    message(sharedContext: sharedContext, saved)
                })
            })
        }, toggle: { accountId in
            var visible = LuckgramDoubleBottomState.shared.visibleAccountIds
            if let index = visible.firstIndex(of: accountId) {
                if visible.count <= 1 {
                    message(sharedContext: sharedContext, atLeastOne)
                    return
                }
                visible.remove(at: index)
            } else {
                visible.append(accountId)
            }
            LuckgramDoubleBottomState.shared.setVisibleAccountIds(visible)
            updateEnabled()
        }, turnOff: {
            requestMainPasscode(sharedContext: sharedContext, challenge: challengeValue, completion: { _ in
                turnOff()
                dismissImpl?()
            })
        })

        let accounts: Signal<[(Int64, String)], NoError> = activeAccountsAndPeers(context: context, includePrimary: true)
        |> map { _, accounts -> [(Int64, String)] in
            return accounts.map { ($0.0.account.id.int64, $0.1.compactDisplayTitle) }
        }
        let challengeSignal = sharedContext.accountManager.accessChallengeData()
        |> map { $0.data }

        let signal = combineLatest(queue: .mainQueue(), sharedContext.presentationData, challengeSignal, accounts, LuckgramDoubleBottomState.shared.updated, hasSecondPromise.get())
        |> map { presentationData, challenge, accounts, _, hasSecond -> (ItemListControllerState, (ItemListNodeState, Any)) in
            var presentationData = presentationData
            presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
            LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
            challengeValue = challenge
            let listEntries = entries(challenge: challenge, accounts: accounts, visible: LuckgramDoubleBottomState.shared.visibleAccountIds, hasSecond: hasSecond)
            let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
            let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: listEntries, style: .blocks, animateChanges: true)
            return (controllerState, (listState, arguments))
        }

        let controller = ItemListController(context: context, state: signal)
        pushImpl = { [weak controller] c in
            controller?.push(c)
        }
        dismissImpl = { [weak controller] in
            controller?.dismiss()
        }
        return controller
    }
}

public func luckgramDoubleBottomController(context: AccountContext) -> ViewController {
    return LuckgramDoubleBottom.controller(context: context)
}
