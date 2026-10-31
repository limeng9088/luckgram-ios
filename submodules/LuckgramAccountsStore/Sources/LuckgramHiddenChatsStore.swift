import Foundation
import SwiftSignalKit

/// Luckgram 12 (hidden chats): the chats each account hid from the chat list, and the two settings
/// (passcode before opening, notifications for hidden chats). Accounts are keyed by their peer id.
/// Kept in `<rootPath>/luckgram-hidden-chats.json` (app group) so the notification service extension
/// can skip hidden chats. Never synced.
public final class LuckgramHiddenChatsStore {
    public static let shared = LuckgramHiddenChatsStore()

    fileprivate struct Values: Codable, Equatable {
        var enabled: Bool = true
        var byAccount: [String: [Int64]] = [:]
        var lock: Bool = false
        var notify: Bool = false
        var hintShown: Bool = false
    }

    private static let fileName = "luckgram-hidden-chats.json"

    private let lock = NSLock()
    private var rootPath: String?
    private var values = Values()
    private let changesPipe = ValuePipe<Void>()

    // Search: hidden chats are left out until the user asks for them, for the current query only.
    private var includeHiddenInSearchValue = false
    private var lastSearchQuery: String?
    private let searchPipe = ValuePipe<Void>()

    private init() {
    }

    public func configure(rootPath: String) {
        self.lock.lock()
        self.rootPath = rootPath
        self.values = LuckgramHiddenChatsStore.read(rootPath: rootPath)
        self.lock.unlock()
        self.changesPipe.putNext(Void())
    }

    public var changes: Signal<Void, NoError> {
        return self.changesPipe.signal() |> deliverOnMainQueue
    }

    /// Emits once now and after every change.
    public var updated: Signal<Void, NoError> {
        return .single(Void()) |> then(self.changes)
    }

    // MARK: - Feature switch (mirrored here for the extension)

    public var isEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.enabled
    }

    public func setEnabled(_ value: Bool) {
        self.update { values in
            values.enabled = value
        }
    }

    // MARK: - Hidden chats

    public func hiddenPeerIds(accountPeerId: Int64) -> [Int64] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.byAccount["\(accountPeerId)"] ?? []
    }

    public func hasHidden(accountPeerId: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.enabled && !(self.values.byAccount["\(accountPeerId)"]?.isEmpty ?? true)
    }

    public func isHidden(accountPeerId: Int64, peerId: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.enabled && (self.values.byAccount["\(accountPeerId)"]?.contains(peerId) ?? false)
    }

    public func setHidden(accountPeerId: Int64, peerId: Int64, _ hidden: Bool) {
        self.update { values in
            var ids = values.byAccount["\(accountPeerId)"] ?? []
            ids.removeAll(where: { $0 == peerId })
            if hidden {
                ids.append(peerId)
            }
            if ids.isEmpty {
                values.byAccount.removeValue(forKey: "\(accountPeerId)")
            } else {
                values.byAccount["\(accountPeerId)"] = ids
            }
        }
    }

    /// New messages in a hidden chat don't notify and don't count, unless the user chose otherwise.
    public func suppressNotifications(accountPeerId: Int64, peerId: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.enabled && !self.values.notify && (self.values.byAccount["\(accountPeerId)"]?.contains(peerId) ?? false)
    }

    // MARK: - Settings

    public var isLockEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.lock
    }

    public func setLockEnabled(_ value: Bool) {
        self.update { values in
            values.lock = value
        }
    }

    public var isNotifyEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.notify
    }

    public func setNotifyEnabled(_ value: Bool) {
        self.update { values in
            values.notify = value
        }
    }

    /// True once: the first time a chat is hidden.
    public func takeFirstHint() -> Bool {
        var result = false
        self.update { values in
            if !values.hintShown {
                values.hintShown = true
                result = true
            }
        }
        return result
    }

    // MARK: - Search

    /// Emits when the "search in hidden chats" choice changes, so the search runs again.
    public var searchUpdated: Signal<Void, NoError> {
        return .single(Void()) |> then(self.searchPipe.signal() |> deliverOnMainQueue)
    }

    public var includeHiddenInSearch: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.includeHiddenInSearchValue
    }

    public func setIncludeHiddenInSearch(_ value: Bool) {
        self.lock.lock()
        let changed = self.includeHiddenInSearchValue != value
        self.includeHiddenInSearchValue = value
        self.lock.unlock()
        if changed {
            self.searchPipe.putNext(Void())
        }
    }

    /// A new query starts without hidden chats again.
    public func noteSearchQuery(_ query: String?) {
        self.lock.lock()
        if self.lastSearchQuery != query {
            self.lastSearchQuery = query
            self.includeHiddenInSearchValue = false
        }
        self.lock.unlock()
    }

    // MARK: - Notification service extension

    public struct Snapshot {
        private let values: Values

        fileprivate init(values: Values) {
            self.values = values
        }

        public func suppressNotifications(accountPeerId: Int64, peerId: Int64) -> Bool {
            return self.values.enabled && !self.values.notify && (self.values.byAccount["\(accountPeerId)"]?.contains(peerId) ?? false)
        }
    }

    public static func snapshot(rootPath: String) -> Snapshot {
        return Snapshot(values: LuckgramHiddenChatsStore.read(rootPath: rootPath))
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
            LuckgramHiddenChatsStore.write(values, rootPath: rootPath)
        }
        self.changesPipe.putNext(Void())
    }

    private static func read(rootPath: String) -> Values {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: rootPath + "/" + fileName)) else {
            return Values()
        }
        return (try? JSONDecoder().decode(Values.self, from: data)) ?? Values()
    }

    private static func write(_ values: Values, rootPath: String) {
        guard let data = try? JSONEncoder().encode(values) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: rootPath + "/" + fileName), options: [.atomic])
    }
}
