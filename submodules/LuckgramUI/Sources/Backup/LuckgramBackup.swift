import Foundation
import CryptoKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import LuckgramAccountsStore

/// Luckgram 10 (account backup): reads the logged-in accounts' permanent keys from their account
/// records and restores accounts as new records. A restored record carries the key as
/// `AccountBackupData`, which `accountWithId` turns into an authorized account — the same path
/// Telegram uses to bring accounts back after a reinstall.
public enum LuckgramBackup {
    public static let featureKey = "account_backup"

    public struct ExportableAccount {
        public let recordId: AccountRecordId
        public let userId: Int64
    }

    /// The accounts of `recordIds` that can be exported (they have a stored permanent key).
    public static func collect(accountManager: AccountManager<TelegramAccountManagerTypes>, recordIds: [AccountRecordId]) -> Signal<[LuckgramBackupFormat.Account], NoError> {
        return accountManager.transaction { transaction -> [LuckgramBackupFormat.Account] in
            var result: [LuckgramBackupFormat.Account] = []
            let records = transaction.getRecords()
            for recordId in recordIds {
                guard let record = records.first(where: { $0.id == recordId }), !isLoggedOut(record) else {
                    continue
                }
                guard let data = backupData(record) else {
                    continue
                }
                let userId = EnginePeer.Id(data.peerId).id._internalGetInt64Value()
                // iOS keeps no server salt with the key; 0 means "none" and the server sends a new one.
                result.append(LuckgramBackupFormat.Account(userId: userId, dcId: data.masterDatacenterId, authKey: data.masterDatacenterKey, serverSalt: 0, name: LuckgramAccountsStore.shared.alias(recordId.int64)))
            }
            return result
        }
    }

    /// User ids of the accounts logged in on this device.
    public static func loggedInUserIds(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<Set<Int64>, NoError> {
        return accountManager.transaction { transaction -> Set<Int64> in
            return loggedInUserIds(transaction.getRecords())
        }
    }

    public struct RestoreResult {
        public var restored: Int = 0
        public var skipped: Int = 0
        public var noRoom: Int = 0
    }

    /// Adds every account that is not logged in yet as a new account record and makes the first one
    /// current (this also closes the login screen). Wipes every key it was given.
    public static func restore(accountManager: AccountManager<TelegramAccountManagerTypes>, accounts: [LuckgramBackupFormat.Account]) -> Signal<RestoreResult, NoError> {
        var accounts = accounts
        return accountManager.transaction { transaction -> (RestoreResult, [(AccountRecordId, String)]) in
            var result = RestoreResult()
            var names: [(AccountRecordId, String)] = []
            let records = transaction.getRecords()
            var loggedIn = loggedInUserIds(records)
            var count = records.filter({ !isLoggedOut($0) }).count
            var nextSortOrder = (records.compactMap({ record -> Int32? in
                for attribute in record.attributes {
                    if case let .sortOrder(sortOrder) = attribute {
                        return sortOrder.order
                    }
                }
                return nil
            }).max() ?? 0) + 1
            var firstId: AccountRecordId?
            for i in 0 ..< accounts.count {
                defer {
                    accounts[i].wipe()
                }
                let account = accounts[i]
                if loggedIn.contains(account.userId) {
                    result.skipped += 1
                    continue
                }
                if count >= LuckgramAccountsStore.maxAccounts {
                    result.noRoom += 1
                    continue
                }
                let peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(account.userId))
                let data = AccountBackupData(
                    masterDatacenterId: account.dcId,
                    peerId: peerId.toInt64(),
                    masterDatacenterKey: account.authKey,
                    masterDatacenterKeyId: authKeyId(account.authKey),
                    notificationEncryptionKeyId: nil,
                    notificationEncryptionKey: nil,
                    additionalDatacenterKeys: [:]
                )
                let id = transaction.createRecord([
                    .environment(AccountEnvironmentAttribute(environment: .production)),
                    .sortOrder(AccountSortOrderAttribute(order: nextSortOrder)),
                    .backupData(AccountBackupDataAttribute(data: data))
                ])
                nextSortOrder += 1
                count += 1
                loggedIn.insert(account.userId)
                result.restored += 1
                if firstId == nil {
                    firstId = id
                }
                if !account.name.isEmpty {
                    names.append((id, account.name))
                }
            }
            if let firstId {
                transaction.setCurrentId(firstId)
                if transaction.getCurrentAuth() != nil {
                    transaction.removeAuth()
                }
            }
            return (result, names)
        }
        |> deliverOnMainQueue
        |> map { result, names -> RestoreResult in
            for (id, name) in names {
                LuckgramAccountsStore.shared.setAlias(id.int64, name)
            }
            return result
        }
    }

    // MARK: - Helpers

    private static func isLoggedOut(_ record: AccountRecord<TelegramAccountManagerTypes.Attribute>) -> Bool {
        return record.attributes.contains(where: { attribute in
            if case .loggedOut = attribute {
                return true
            }
            return false
        })
    }

    private static func backupData(_ record: AccountRecord<TelegramAccountManagerTypes.Attribute>) -> AccountBackupData? {
        for attribute in record.attributes {
            if case let .backupData(backupData) = attribute {
                return backupData.data
            }
        }
        return nil
    }

    private static func loggedInUserIds(_ records: [AccountRecord<TelegramAccountManagerTypes.Attribute>]) -> Set<Int64> {
        var result = Set<Int64>()
        for record in records where !isLoggedOut(record) {
            if let data = backupData(record) {
                result.insert(EnginePeer.Id(data.peerId).id._internalGetInt64Value())
            }
        }
        return result
    }

    /// auth_key_id: the lower 64 bits of SHA1(auth_key), little endian (MTProto).
    static func authKeyId(_ authKey: Data) -> Int64 {
        let digest = Array(Insecure.SHA1.hash(data: authKey))
        var value: Int64 = 0
        for i in (0 ..< 8).reversed() {
            value = (value << 8) | Int64(digest[12 + i])
        }
        return value
    }
}
