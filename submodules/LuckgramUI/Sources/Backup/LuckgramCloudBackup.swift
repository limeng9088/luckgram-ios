import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// Luckgram 32 strings; same texts as Android `CloudBackup`.
public enum LuckgramCloudBackupStrings {
    public static var header: String { LuckgramStrings.pick("云备份", "Cloud backup") }
    public static var proOnly: String { LuckgramStrings.pick("Pro 专享：把加密后的账号备份存到云端，换手机后登录任意一个账号即可恢复。", "Pro: keep an encrypted account backup in the cloud and restore it on a new phone after logging in to any one account.") }
    public static var upload: String { LuckgramStrings.pick("备份到云端", "Back up to cloud") }
    public static var restore: String { LuckgramStrings.pick("从云端恢复", "Restore from cloud") }
    public static var restoreFromFile: String { LuckgramStrings.pick("从文件恢复", "Restore from file") }
    public static var delete: String { LuckgramStrings.pick("删除云备份", "Delete cloud backup") }
    public static var deleteConfirm: String { LuckgramStrings.pick("删除后云端不再保存这份备份，无法撤销。", "The backup will be removed from the cloud. This can't be undone.") }
    public static var auto: String { LuckgramStrings.pick("每周自动备份", "Back up weekly") }
    public static var autoInfo: String { LuckgramStrings.pick("开启时需要在本机记住备份密码（保存在系统钥匙串，不会上传）。关闭后会从本机删除这个密码。", "Requires remembering the backup password on this device (kept in the system Keychain, never uploaded). Turning it off removes the password from this device.") }
    public static var remember: String { LuckgramStrings.pick("在本机记住备份密码（存系统钥匙串），用于每周自动备份？", "Remember the backup password on this device (system Keychain) for the weekly backup?") }
    public static var rememberYes: String { LuckgramStrings.pick("记住并开启", "Remember and turn on") }
    public static var rememberNo: String { LuckgramStrings.pick("不记住", "Don't remember") }
    public static var warning: String { LuckgramStrings.pick("云端只保存加密后的数据，Luckgram 无法解密；忘记密码将无法恢复。", "The cloud only keeps encrypted data that Luckgram can't decrypt. If you forget the password, the backup can't be restored.") }
    public static var loading: String { LuckgramStrings.pick("正在读取云备份…", "Checking cloud backup…") }
    public static var noBackup: String { LuckgramStrings.pick("云端还没有备份", "No cloud backup yet") }
    public static func status(_ meta: LuckgramCloudBackupLogic.Meta) -> String {
        let when: String
        if meta.createdAt > 0 {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            when = formatter.string(from: Date(timeIntervalSince1970: meta.createdAt))
        } else {
            when = "—"
        }
        return LuckgramStrings.pick("最近一次云备份：\(when) · \(meta.accounts) 个账号", "Last cloud backup: \(when) · \(meta.accounts) \(meta.accounts == 1 ? "account" : "accounts")")
    }
    public static var uploaded: String { LuckgramStrings.pick("已备份到云端", "Backed up to cloud") }
    public static var deleted: String { LuckgramStrings.pick("云备份已删除", "Cloud backup deleted") }
    public static var needAccount: String { LuckgramStrings.pick("请先登录任意一个账号，再从云端恢复。", "Log in to any one account first, then restore from the cloud.") }
    public static var notLinked: String { LuckgramStrings.pick("暂时无法连接 Luckgram 服务，请稍后再试。", "Can't reach the Luckgram service right now. Try again later.") }
    public static func error(_ error: LuckgramAIError) -> String {
        switch error.code {
        case "not_pro":
            return LuckgramStrings.pick("云备份是 Pro 专享功能。", "Cloud backup is a Pro feature.")
        case "not_linked":
            return notLinked
        default:
            return error.localizedMessage
        }
    }
}

/// Luckgram 32: cloud backup (Pro). The 10 backup file is encrypted on this device with the user's
/// password and only that ciphertext is uploaded to `/v1/backup` (S15). The password is never
/// sent; it is kept in the Keychain only when the user turns on the weekly automatic backup.
public enum LuckgramCloudBackup {
    private static let autoKey = "cloud_backup.auto"
    private static let lastAutoKey = "cloud_backup.last_auto"
    private static let lastTryKey = "cloud_backup.last_try"
    /// Keychain account; never uploaded.
    private static let passwordAccount = "cloud_backup.password"
    /// A failed weekly upload is retried after this long, not on every foreground.
    private static let retryInterval: TimeInterval = 6 * 60 * 60
    private static var autoRunning = false

    private static let notLinkedError = LuckgramAIError(code: "not_linked")

    // MARK: Requests (main queue)

    /// The backup belongs to the Telegram user linked to this device (S6). With a context, link
    /// silently first; without one (login screen) the device must already be linked.
    private static func linked(context: AccountContext?) -> Signal<Void, LuckgramAIError> {
        if let context {
            return Signal { subscriber in
                LuckgramSilentLink.ensure(context: context, completion: { ok in
                    if ok {
                        subscriber.putNext(Void())
                        subscriber.putCompletion()
                    } else {
                        subscriber.putError(notLinkedError)
                    }
                })
                return EmptyDisposable
            }
        }
        return LuckgramSilentLink.refresh()
        |> castError(LuckgramAIError.self)
        |> mapToSignal { value -> Signal<Void, LuckgramAIError> in
            return value == true ? .single(Void()) : .fail(notLinkedError)
        }
    }

    /// `GET /v1/backup`; nil when there is no backup.
    public static func fetch(context: AccountContext?) -> Signal<LuckgramCloudBackupLogic.Meta?, LuckgramAIError> {
        return linked(context: context)
        |> mapToSignal { _ -> Signal<LuckgramCloudBackupLogic.Meta?, LuckgramAIError> in
            return LuckgramAI.shared.requestJSON(method: "GET", path: LuckgramCloudBackupLogic.path)
            |> map { LuckgramCloudBackupLogic.parseMeta($0) }
            |> `catch` { error -> Signal<LuckgramCloudBackupLogic.Meta?, LuckgramAIError> in
                if LuckgramCloudBackupLogic.isNotFound(code: error.code, httpStatus: error.httpStatus) {
                    return .single(nil)
                }
                return .fail(error)
            }
        }
        |> deliverOnMainQueue
    }

    /// The encrypted file of the latest cloud backup, or nil when there is none.
    public static func download(context: AccountContext?) -> Signal<Data?, LuckgramAIError> {
        return fetch(context: context)
        |> map { meta -> Data? in
            guard let data = meta?.data else {
                return nil
            }
            return Data(base64Encoded: data, options: .ignoreUnknownCharacters)
        }
    }

    /// Encrypts every logged-in account with `password` off the main queue (same file as 10's
    /// export), wipes the keys, then uploads only the ciphertext.
    public static func upload(accountManager: AccountManager<TelegramAccountManagerTypes>, context: AccountContext?, password: String) -> Signal<LuckgramCloudBackupLogic.Meta, LuckgramAIError> {
        return LuckgramBackup.collectAll(accountManager: accountManager)
        |> deliverOn(Queue.concurrentDefaultQueue())
        |> map { items -> (String, Int)? in
            var items = items
            defer {
                for i in items.indices {
                    items[i].wipe()
                }
            }
            guard !items.isEmpty, let data = try? LuckgramBackupFormat.encrypt(accounts: items, password: password) else {
                return nil
            }
            return (data.base64EncodedString(), items.count)
        }
        |> castError(LuckgramAIError.self)
        |> deliverOnMainQueue
        |> mapToSignal { encoded -> Signal<LuckgramCloudBackupLogic.Meta, LuckgramAIError> in
            guard let encoded else {
                return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
            }
            let (data, count) = encoded
            let now = Date().timeIntervalSince1970
            let body = LuckgramCloudBackupLogic.uploadBody(dataBase64: data, accounts: count, createdAt: now)
            return linked(context: context)
            |> mapToSignal { _ -> Signal<LuckgramCloudBackupLogic.Meta, LuckgramAIError> in
                return LuckgramAI.shared.requestJSON(method: "PUT", path: LuckgramCloudBackupLogic.path, body: body)
                |> map { response -> LuckgramCloudBackupLogic.Meta in
                    return LuckgramCloudBackupLogic.parseMeta(response) ?? LuckgramCloudBackupLogic.Meta(accounts: count, createdAt: now, data: nil)
                }
            }
        }
        |> deliverOnMainQueue
    }

    /// `DELETE /v1/backup`.
    public static func delete(context: AccountContext?) -> Signal<Void, LuckgramAIError> {
        return linked(context: context)
        |> mapToSignal { _ -> Signal<Void, LuckgramAIError> in
            return LuckgramAI.shared.requestJSON(method: "DELETE", path: LuckgramCloudBackupLogic.path)
            |> map { _ in Void() }
            |> `catch` { error -> Signal<Void, LuckgramAIError> in
                if LuckgramCloudBackupLogic.isNotFound(code: error.code, httpStatus: error.httpStatus) {
                    return .single(Void())
                }
                return .fail(error)
            }
        }
        |> deliverOnMainQueue
    }

    // MARK: Weekly automatic backup

    public static var hasRememberedPassword: Bool {
        return (LuckgramKeychain.get(account: passwordAccount)?.count ?? 0) >= LuckgramBackupFormat.minPasswordLength
    }

    public static var isAutoEnabled: Bool {
        return LuckgramSettings.shared.bool(autoKey, default: false) && hasRememberedPassword
    }

    /// Turns the weekly backup on with `password` kept in the Keychain, or off (password removed).
    public static func setAuto(password: String?) {
        if let password, password.count >= LuckgramBackupFormat.minPasswordLength {
            let saved = LuckgramKeychain.set(account: passwordAccount, value: password)
            LuckgramSettings.shared.setBool(autoKey, saved)
        } else {
            LuckgramKeychain.delete(account: passwordAccount)
            LuckgramSettings.shared.setBool(autoKey, false)
            LuckgramSettings.shared.setInt(lastAutoKey, 0)
        }
    }

    public static func markUploaded() {
        LuckgramSettings.shared.setInt(lastAutoKey, Int(Date().timeIntervalSince1970))
    }

    /// Called when the app comes to the foreground; uploads at most once a week, Pro only.
    public static func runAutoIfDue(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        if autoRunning || !luckgramIsPro() || !LuckgramSettings.shared.bool(autoKey, default: false) {
            return
        }
        let password = LuckgramKeychain.get(account: passwordAccount)
        let now = Date().timeIntervalSince1970
        let last = TimeInterval(LuckgramSettings.shared.int(lastAutoKey, default: 0))
        if !LuckgramCloudBackupLogic.autoBackupDue(enabled: true, passwordRemembered: password != nil, last: last, now: now) {
            return
        }
        let lastTry = TimeInterval(LuckgramSettings.shared.int(lastTryKey, default: 0))
        if lastTry > 0, lastTry <= now, now - lastTry < retryInterval {
            return
        }
        guard let password else {
            return
        }
        LuckgramSettings.shared.setInt(lastTryKey, Int(now))
        autoRunning = true
        let _ = upload(accountManager: accountManager, context: nil, password: password).start(next: { _ in
            autoRunning = false
            markUploaded()
        }, error: { _ in
            autoRunning = false
        })
    }
}
