import Foundation

/// Luckgram spec 13 (受限频道): which restriction rules the `store_restrictions_off` switch may
/// ignore. Foundation only, unit tested on Linux; same rule as Android
/// `org.telegram.luckgram.unblock.StoreRestrictions`.
///
/// A rule's `platform` is a dash-separated list such as `ios`, `android`, `ios-android`, `all` or
/// `ios-all`. Only rules that name app-store platforms and nothing else are store restrictions.
/// Anything containing `all` (Telegram's all-platform bans) or an unknown token stays in force, and
/// so does everything the server enforces itself (regional blocks are refused by the server).
///
/// The app sets `isEnabled` from `LuckgramSettings` (TelegramCore cannot depend on LuckgramUI).
public enum LuckgramStoreRestrictions {
    private static let lock = NSLock()
    private static var enabledValue = false

    public static var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabledValue
        }
        set {
            lock.lock()
            enabledValue = newValue
            lock.unlock()
        }
    }

    /// True if the rule applies only to the App Store / Google Play builds.
    public static func isStoreOnly(_ platform: String) -> Bool {
        var any = false
        for token in platform.lowercased().split(separator: "-", omittingEmptySubsequences: true) {
            if token != "ios" && token != "android" {
                return false
            }
            any = true
        }
        return any
    }

    /// Whether a rule must be skipped: the switch is on and the rule is store-only.
    public static func ignore(_ platform: String, switchOn: Bool) -> Bool {
        return switchOn && isStoreOnly(platform)
    }

    /// `ignore(_:switchOn:)` with the current switch.
    public static func ignore(_ platform: String) -> Bool {
        return ignore(platform, switchOn: isEnabled)
    }
}
