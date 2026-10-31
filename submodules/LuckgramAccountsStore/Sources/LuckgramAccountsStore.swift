import Foundation
import SwiftSignalKit

/// Luckgram 09 (more accounts): account order, a local name per account and a notification switch
/// per account (same behaviour as Android `org.telegram.luckgram.accounts.LuckgramAccounts`).
///
/// Accounts are identified by their `AccountRecordId` value. The values live in one small JSON file
/// in the app group container (`<rootPath>/luckgram-accounts.json`) so that the notification service
/// extension can read the notification switch and the local name. Nothing here leaves the device.
public final class LuckgramAccountsStore {
    /// Maximum number of accounts logged in at the same time (spec 09: 20, for everyone).
    public static let maxAccounts = 20
    /// The settings account list shows this many other accounts before it collapses.
    public static let collapsedCount = 5
    /// Longest local name.
    public static let aliasMaxLength = 32

    public static let shared = LuckgramAccountsStore()

    fileprivate struct Values: Codable, Equatable {
        var order: [Int64] = []
        var aliases: [String: String] = [:]
        var notificationsOff: [Int64] = []
    }

    private static let fileName = "luckgram-accounts.json"

    private let lock = NSLock()
    private var rootPath: String?
    private var values = Values()
    private var expandedValue = false
    private let changesPipe = ValuePipe<Void>()

    private init() {
    }

    /// Called once at app start with the shared container root (`rootPath`).
    public func configure(rootPath: String) {
        self.lock.lock()
        self.rootPath = rootPath
        self.values = LuckgramAccountsStore.read(rootPath: rootPath)
        self.lock.unlock()
        self.changesPipe.putNext(Void())
    }

    // MARK: - Change notification

    /// Emits after every change (order, names, switches, collapsed state). Delivered on the main queue.
    public var changes: Signal<Void, NoError> {
        return self.changesPipe.signal() |> deliverOnMainQueue
    }

    /// Emits once now and after every change.
    public var updated: Signal<Void, NoError> {
        return .single(Void()) |> then(self.changes)
    }

    // MARK: - Order

    /// Sorts `items` by the user's order. Accounts without a saved place keep their relative order
    /// and go after the ordered ones (new accounts end up at the bottom).
    public func sorted<T>(_ items: [T], id: (T) -> Int64) -> [T] {
        self.lock.lock()
        let order = self.values.order
        self.lock.unlock()
        var position: [Int64: Int] = [:]
        for (index, value) in order.enumerated() {
            position[value] = index
        }
        return items.enumerated().sorted { lhs, rhs in
            let p1 = position[id(lhs.element)]
            let p2 = position[id(rhs.element)]
            switch (p1, p2) {
            case let (p1?, p2?):
                return p1 < p2
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Saves a new order. `ids` may be a subset of the accounts: the listed accounts take the
    /// places they had before, so accounts that are not listed keep theirs.
    public func setOrder(_ ids: [Int64], allAccounts: [Int64]) {
        var all = self.sorted(allAccounts, id: { $0 })
        var slots: [Int] = []
        for (index, value) in all.enumerated() where ids.contains(value) {
            slots.append(index)
        }
        for (slot, value) in zip(slots, ids) {
            all[slot] = value
        }
        self.update { values in
            values.order = all
        }
    }

    // MARK: - Collapsed list (in memory)

    /// Whether the settings account list shows every account.
    public var isExpanded: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.expandedValue
    }

    public func setExpanded(_ value: Bool) {
        self.lock.lock()
        let changed = self.expandedValue != value
        self.expandedValue = value
        self.lock.unlock()
        if changed {
            self.changesPipe.putNext(Void())
        }
    }

    // MARK: - Local names

    public func alias(_ accountId: Int64) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let value = self.values.aliases["\(accountId)"]
        return (value?.isEmpty ?? true) ? nil : value
    }

    public func setAlias(_ accountId: Int64, _ alias: String?) {
        var value = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = value, current.count > LuckgramAccountsStore.aliasMaxLength {
            value = String(current.prefix(LuckgramAccountsStore.aliasMaxLength))
        }
        self.update { values in
            if let value, !value.isEmpty {
                values.aliases["\(accountId)"] = value
            } else {
                values.aliases.removeValue(forKey: "\(accountId)")
            }
        }
    }

    /// Name shown in account lists: "Alias (Name)" when a local name is set.
    public func displayName(_ accountId: Int64, name: String) -> String {
        guard let alias = self.alias(accountId) else {
            return name
        }
        return name.isEmpty ? alias : "\(alias) (\(name))"
    }

    // MARK: - Notifications

    public func isNotificationsEnabled(_ accountId: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.values.notificationsOff.contains(accountId)
    }

    public func setNotificationsEnabled(_ accountId: Int64, _ enabled: Bool) {
        self.update { values in
            values.notificationsOff.removeAll(where: { $0 == accountId })
            if !enabled {
                values.notificationsOff.append(accountId)
            }
        }
    }

    // MARK: - Logout

    /// Drops everything stored for an account that was removed from the device.
    public func accountRemoved(_ accountId: Int64) {
        self.update { values in
            values.order.removeAll(where: { $0 == accountId })
            values.aliases.removeValue(forKey: "\(accountId)")
            values.notificationsOff.removeAll(where: { $0 == accountId })
        }
    }

    // MARK: - Notification service extension

    /// Read-only snapshot for the notification service extension, which has no shared instance.
    public struct Snapshot {
        private let values: Values

        fileprivate init(values: Values) {
            self.values = values
        }

        public func isNotificationsEnabled(_ accountId: Int64) -> Bool {
            return !self.values.notificationsOff.contains(accountId)
        }

        public func alias(_ accountId: Int64) -> String? {
            let value = self.values.aliases["\(accountId)"]
            return (value?.isEmpty ?? true) ? nil : value
        }
    }

    public static func snapshot(rootPath: String) -> Snapshot {
        return Snapshot(values: LuckgramAccountsStore.read(rootPath: rootPath))
    }

    /// Notification title with the account in front: "[Work] Noah". `accountName` is the local name
    /// or the account's own name; nil leaves the title as it is.
    public static func notificationTitle(_ title: String, accountName: String?) -> String {
        guard let accountName, !accountName.isEmpty else {
            return title
        }
        return "[\(accountName)] \(title)"
    }

    // MARK: - Storage

    private func update(_ f: (inout Values) -> Void) {
        self.lock.lock()
        var values = self.values
        f(&values)
        let changed = values != self.values
        self.values = values
        let rootPath = self.rootPath
        self.lock.unlock()
        guard changed else {
            return
        }
        if let rootPath {
            LuckgramAccountsStore.write(values, rootPath: rootPath)
        }
        self.changesPipe.putNext(Void())
    }

    private static func path(rootPath: String) -> String {
        return rootPath + "/" + LuckgramAccountsStore.fileName
    }

    private static func read(rootPath: String) -> Values {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: LuckgramAccountsStore.path(rootPath: rootPath))) else {
            return Values()
        }
        return (try? JSONDecoder().decode(Values.self, from: data)) ?? Values()
    }

    private static func write(_ values: Values, rootPath: String) {
        guard let data = try? JSONEncoder().encode(values) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: LuckgramAccountsStore.path(rootPath: rootPath)), options: [.atomic])
    }
}
