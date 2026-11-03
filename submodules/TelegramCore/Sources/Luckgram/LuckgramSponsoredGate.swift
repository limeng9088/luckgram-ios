import Foundation

/// Luckgram 29 (specs#87) 需求 4: Pro users see no sponsored messages. Set from the app's Pro state
/// (LuckgramUI `LuckgramPro`, which TelegramCore cannot import); while it says Pro, sponsored
/// messages are neither loaded (nor taken from the cache) nor reported as viewed / clicked.
public enum LuckgramSponsoredGate {
    private static let lock = NSLock()
    private static var active = false
    private static var expiresAt: Date?

    public static func setPro(active: Bool, expiresAt: Date?) {
        lock.lock()
        self.active = active
        self.expiresAt = expiresAt
        lock.unlock()
    }

    /// True while the user is Pro (until the known expiry).
    public static var hidden: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else {
            return false
        }
        if let expiresAt {
            return Date() < expiresAt
        }
        return true
    }
}
