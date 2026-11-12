import Foundation

/// Luckgram 32 / 135: how many accounts can be logged in at once. Free users get
/// `accounts.max_free` (default 10, remote config); Pro has no product limit and is only bound by the
/// slot capacity. Same rules as Android `AccountLimit`. Foundation only, unit tested.
public enum LuckgramAccountLimit {
    public static let slotCapacity = 50
    public static let defaultMaxFree = 10
    public static let maxFreeKey = "accounts.max_free"

    /// Free limit: remote value, at least 1, at most the slot capacity.
    public static func maxFree(_ remoteMaxFree: Int) -> Int {
        return max(1, min(slotCapacity, remoteMaxFree))
    }

    /// Pro limit: no product limit, only the slot capacity.
    public static var maxPro: Int {
        return slotCapacity
    }

    public static func limit(isPro: Bool, remoteMaxFree: Int) -> Int {
        return isPro ? maxPro : maxFree(remoteMaxFree)
    }

    /// Never logs accounts out (free users above the limit, expired Pro): only adding is blocked.
    public static func canAdd(activated: Int, limit: Int) -> Bool {
        return activated < limit
    }

    /// Offer "upgrade to Pro" only to free users and only when Pro raises the limit.
    public static func offerUpgrade(isPro: Bool, remoteMaxFree: Int) -> Bool {
        return !isPro && maxPro > maxFree(remoteMaxFree)
    }
}
