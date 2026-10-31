import Foundation
import SwiftSignalKit

/// Luckgram 11 (double space): which accounts are visible with the second passcode and whether
/// the app was unlocked with it. Kept in `<rootPath>/luckgram-double-bottom.json` (app group) so
/// the notification service extension can skip hidden accounts. The second passcode itself is
/// never here: its salted hash lives in the app's Keychain (`LuckgramDoubleBottom`).
public final class LuckgramDoubleBottomState {
    public static let shared = LuckgramDoubleBottomState()

    private struct Values: Codable, Equatable {
        var active: Bool = false
        var visible: [Int64] = []
    }

    private static let fileName = "luckgram-double-bottom.json"

    private let lock = NSLock()
    private var rootPath: String?
    private var values = Values()
    private let changesPipe = ValuePipe<Void>()

    /// Set by the app (LuckgramUI): true when `code` is the second passcode and the feature is on.
    public var secondPasscodeCheck: ((String) -> Bool)?

    private init() {
    }

    public func configure(rootPath: String) {
        self.lock.lock()
        self.rootPath = rootPath
        self.values = LuckgramDoubleBottomState.read(rootPath: rootPath)
        self.lock.unlock()
        self.changesPipe.putNext(Void())
    }

    public var changes: Signal<Void, NoError> {
        return self.changesPipe.signal() |> deliverOnMainQueue
    }

    public var updated: Signal<Void, NoError> {
        return .single(Void()) |> then(self.changes)
    }

    // MARK: - State

    /// The app is in the second space (unlocked with the second passcode).
    public var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.active && !self.values.visible.isEmpty
    }

    public var visibleAccountIds: [Int64] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.visible
    }

    public func setVisibleAccountIds(_ ids: [Int64]) {
        self.update { values in
            values.visible = ids
        }
    }

    /// Whether the account must not appear anywhere while the second space is open.
    public func isHidden(_ accountId: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.active && !self.values.visible.isEmpty && !self.values.visible.contains(accountId)
    }

    /// Called by the passcode screen with what the user typed. True opens the second space.
    public func tryUnlockWithSecondPasscode(_ code: String) -> Bool {
        guard let check = self.secondPasscodeCheck, check(code) else {
            return false
        }
        self.update { values in
            values.active = true
        }
        return true
    }

    /// Main passcode accepted: everything is visible again.
    public func onMainUnlock() {
        self.update { values in
            values.active = false
        }
    }

    /// Feature switched off.
    public func reset() {
        self.update { values in
            values = Values()
        }
    }

    public func accountRemoved(_ accountId: Int64) {
        self.update { values in
            values.visible.removeAll(where: { $0 == accountId })
        }
    }

    // MARK: - Notification service extension

    public struct Snapshot {
        private let values: Values

        fileprivate init(values: Values) {
            self.values = values
        }

        public func isHidden(_ accountId: Int64) -> Bool {
            return self.values.active && !self.values.visible.isEmpty && !self.values.visible.contains(accountId)
        }
    }

    public static func snapshot(rootPath: String) -> Snapshot {
        return Snapshot(values: LuckgramDoubleBottomState.read(rootPath: rootPath))
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
            LuckgramDoubleBottomState.write(values, rootPath: rootPath)
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
