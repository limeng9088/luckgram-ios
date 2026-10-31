import Foundation

/// Platform-independent refresh rule of the remote config client (task S4); parsing is `LuckgramRemoteConfig` (00). Foundation only, unit tested
/// on Linux (`.github/workflows/luckgram-unit-tests.yml`). Same rules on Android
/// (`org.telegram.luckgram.LuckgramRemoteConfigLogic`).
public enum LuckgramRemoteConfigLogic {
    /// Used until the server has sent `client.config_ttl_seconds`.
    public static let defaultTTLSeconds: Double = 3600.0
    /// After a failed fetch, wait this long before trying again (the cache stays in use).
    public static let retryAfterFailureSeconds: Double = 300.0

    /// Whether the cached config should be refreshed now (all times are seconds since 1970).
    public static func isStale(now: Double, fetchedAt: Double, ttlSeconds: Double, lastFailure: Double) -> Bool {
        if lastFailure > 0.0 && now >= lastFailure && now - lastFailure < retryAfterFailureSeconds {
            return false
        }
        if fetchedAt <= 0.0 || now < fetchedAt {
            return true
        }
        let ttl = ttlSeconds > 0.0 ? ttlSeconds : defaultTTLSeconds
        return now - fetchedAt >= ttl
    }
}
