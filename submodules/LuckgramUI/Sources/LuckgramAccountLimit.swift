import Foundation

/// Luckgram 32: how many accounts can be logged in at once. Free and Pro limits come from remote
/// config (`accounts.max_free` / `accounts.max_pro`); same rules as Android `AccountLimit`.
/// Foundation only, unit tested.
public enum LuckgramAccountLimit {
    public static let slotCapacity = 50
    public static let defaultMaxFree = 20
    public static let defaultMaxPro = 50
    public static let maxFreeKey = "accounts.max_free"
    public static let maxProKey = "accounts.max_pro"

    /// Free limit: remote value, at least 20, at most the slot capacity.
    public static func maxFree(_ remoteMaxFree: Int) -> Int {
        return max(defaultMaxFree, min(slotCapacity, remoteMaxFree))
    }

    /// Pro limit: remote value, never below the free limit, at most the slot capacity.
    public static func maxPro(remoteMaxFree: Int, remoteMaxPro: Int) -> Int {
        return max(maxFree(remoteMaxFree), min(slotCapacity, remoteMaxPro))
    }

    public static func limit(isPro: Bool, remoteMaxFree: Int, remoteMaxPro: Int) -> Int {
        return isPro ? maxPro(remoteMaxFree: remoteMaxFree, remoteMaxPro: remoteMaxPro) : maxFree(remoteMaxFree)
    }

    /// Pro expiry never logs accounts out: only adding is blocked once `activated >= limit`.
    public static func canAdd(activated: Int, limit: Int) -> Bool {
        return activated < limit
    }

    /// Offer "upgrade to Pro" only to free users and only when Pro raises the limit.
    public static func offerUpgrade(isPro: Bool, remoteMaxFree: Int, remoteMaxPro: Int) -> Bool {
        return !isPro && maxPro(remoteMaxFree: remoteMaxFree, remoteMaxPro: remoteMaxPro) > maxFree(remoteMaxFree)
    }
}
