import Foundation
import SwiftSignalKit

/// Luckgram switch and config storage (same name and keys as Android `org.telegram.luckgram.LuckgramSettings`).
///
/// - Stored per device in its own `UserDefaults` suite; never synced to the cloud.
/// - Shared by all accounts on the device. Features whose spec says "per account" use the
///   `forAccount:` variants; those values are removed when that account logs out.
/// - Every change is published on `changes` (the key, or nil when many keys changed).
/// - When the last account logs out, everything Luckgram stored on the device is wiped.
public final class LuckgramSettings {
    public static let shared = LuckgramSettings()

    private static let suiteName = "luckgram_settings"
    private static let debugToolsKey = "_debug_tools_unlocked"
    private static let installMarkerKey = "_installed"
    private static let remoteConfigKey = "_remote_config"

    private let defaults: UserDefaults
    private let changesPipe = ValuePipe<String?>()
    private let remoteConfigLock = NSLock()
    private var remoteConfigValue: [String: Any]?

    private init() {
        self.defaults = UserDefaults(suiteName: LuckgramSettings.suiteName) ?? .standard
        if !self.defaults.bool(forKey: LuckgramSettings.installMarkerKey) {
            // Fresh install: the Keychain survives app deletion on iOS, so drop anything an
            // earlier installation left behind.
            LuckgramKeychain.delete(account: LuckgramKeychain.deviceTokenAccount)
            self.defaults.set(true, forKey: LuckgramSettings.installMarkerKey)
        }
    }

    // MARK: - Change notification

    /// Emits the changed key (or nil when many keys changed at once). Delivered on the main queue.
    public var changes: Signal<String?, NoError> {
        return self.changesPipe.signal() |> deliverOnMainQueue
    }

    /// Current value of a registered switch, followed by every change.
    public func isEnabledSignal(_ key: String) -> Signal<Bool, NoError> {
        return .single(self.isEnabled(key))
        |> then(self.changes |> filter { $0 == nil || $0 == key } |> map { [weak self] _ in
            return self?.isEnabled(key) ?? false
        })
        |> distinctUntilChanged
    }

    /// Emits once now and again after every change; for screens that rebuild from the registry.
    public var updated: Signal<Void, NoError> {
        return .single(Void()) |> then(self.changes |> map { _ in Void() })
    }

    private func notifyChanged(_ key: String?) {
        self.changesPipe.putNext(key)
    }

    // MARK: - Registered switches

    /// Switch state of a registered feature (falls back to the registry default).
    public func isEnabled(_ key: String) -> Bool {
        let defaultValue = LuckgramFeatures.find(key)?.defaultValue ?? false
        return self.bool(key, default: defaultValue)
    }

    public func setEnabled(_ key: String, _ value: Bool) {
        self.setBool(key, value)
    }

    // MARK: - Generic values (device)

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if self.defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return self.defaults.bool(forKey: key)
    }

    public func setBool(_ key: String, _ value: Bool) {
        self.defaults.set(value, forKey: key)
        self.notifyChanged(key)
    }

    public func string(_ key: String, default defaultValue: String?) -> String? {
        return self.defaults.string(forKey: key) ?? defaultValue
    }

    public func setString(_ key: String, _ value: String?) {
        if let value {
            self.defaults.set(value, forKey: key)
        } else {
            self.defaults.removeObject(forKey: key)
        }
        self.notifyChanged(key)
    }

    public func int(_ key: String, default defaultValue: Int) -> Int {
        if self.defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return self.defaults.integer(forKey: key)
    }

    public func setInt(_ key: String, _ value: Int) {
        self.defaults.set(value, forKey: key)
        self.notifyChanged(key)
    }

    public func remove(_ key: String) {
        self.defaults.removeObject(forKey: key)
        self.notifyChanged(key)
    }

    // MARK: - Per-account values

    private func accountKey(_ accountId: Int64, _ key: String) -> String {
        return "acc\(accountId).\(key)"
    }

    public func bool(_ key: String, forAccount accountId: Int64, default defaultValue: Bool) -> Bool {
        return self.bool(self.accountKey(accountId, key), default: defaultValue)
    }

    public func setBool(_ key: String, _ value: Bool, forAccount accountId: Int64) {
        self.setBool(self.accountKey(accountId, key), value)
    }

    public func string(_ key: String, forAccount accountId: Int64, default defaultValue: String?) -> String? {
        return self.string(self.accountKey(accountId, key), default: defaultValue)
    }

    public func setString(_ key: String, _ value: String?, forAccount accountId: Int64) {
        self.setString(self.accountKey(accountId, key), value)
    }

    public func int(_ key: String, forAccount accountId: Int64, default defaultValue: Int) -> Int {
        return self.int(self.accountKey(accountId, key), default: defaultValue)
    }

    public func setInt(_ key: String, _ value: Int, forAccount accountId: Int64) {
        self.setInt(self.accountKey(accountId, key), value)
    }

    // MARK: - Remote config (GET /v1/config, task S4)

    /// Merges the body of `GET /v1/config` (a flat object of `client: true` keys, e.g.
    /// `"features.quick_replies": true`, `"ai.transcribe_max_mb": 25`) and caches it.
    /// Fetching and TTL handling are task S4.
    public func mergeRemoteConfig(_ config: [String: Any]) {
        self.remoteConfigLock.lock()
        var merged = self.loadRemoteConfigLocked()
        for (key, value) in config {
            merged[key] = value
        }
        self.remoteConfigValue = merged
        if let data = try? JSONSerialization.data(withJSONObject: merged) {
            self.defaults.set(data, forKey: LuckgramSettings.remoteConfigKey)
        }
        self.remoteConfigLock.unlock()
        self.notifyChanged(nil)
    }

    private func loadRemoteConfigLocked() -> [String: Any] {
        if let value = self.remoteConfigValue {
            return value
        }
        var result: [String: Any] = [:]
        if let data = self.defaults.data(forKey: LuckgramSettings.remoteConfigKey), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = object
        }
        self.remoteConfigValue = result
        return result
    }

    private func remoteValue(_ key: String) -> Any? {
        self.remoteConfigLock.lock()
        defer { self.remoteConfigLock.unlock() }
        return self.loadRemoteConfigLocked()[key]
    }

    /// Whether the server allows the feature (`features.<key>`); true when unknown.
    public func isRemotelyAllowed(_ featureKey: String) -> Bool {
        let value = self.remoteValue("features.\(featureKey)")
        if let value = value as? Bool {
            return value
        }
        if let value = value as? [String: Any], let enabled = value["enabled"] as? Bool {
            return enabled
        }
        return true
    }

    /// A `client: true` number from /v1/config, or `defaultValue` (the built-in default with the same name).
    public func remoteInt(_ key: String, default defaultValue: Int) -> Int {
        if let value = self.remoteValue(key) as? NSNumber {
            return value.intValue
        }
        return defaultValue
    }

    // MARK: - Debug tools

    /// Debug builds, or release builds after tapping the version on the Luckgram page 7 times.
    public var isDebugToolsVisible: Bool {
        #if DEBUG
        return true
        #else
        return self.bool(LuckgramSettings.debugToolsKey, default: false)
        #endif
    }

    public func toggleDebugToolsUnlocked() {
        self.setBool(LuckgramSettings.debugToolsKey, !self.bool(LuckgramSettings.debugToolsKey, default: false))
    }

    // MARK: - Logout cleanup

    /// Called when an account is removed from the device (logout or account deletion).
    public func accountRemoved(accountId: Int64, noAccountsLeft: Bool) {
        if noAccountsLeft {
            for key in self.defaults.dictionaryRepresentation().keys where key != LuckgramSettings.installMarkerKey {
                self.defaults.removeObject(forKey: key)
            }
            self.remoteConfigLock.lock()
            self.remoteConfigValue = nil
            self.remoteConfigLock.unlock()
            LuckgramAI.shared.resetLocalState()
        } else {
            let prefix = "acc\(accountId)."
            for key in self.defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                self.defaults.removeObject(forKey: key)
            }
        }
        self.notifyChanged(nil)
    }
}
