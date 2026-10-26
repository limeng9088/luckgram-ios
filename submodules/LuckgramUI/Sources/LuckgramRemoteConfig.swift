import Foundation

/// A parsed `GET /v1/config` response (task S4, issue #56), same as Android `LuckgramRemoteConfig`:
///
///     {"version": "…", "ttl": 3600,
///      "values":   {"ai.transcribe_max_mb": 4, "quota.free.chat_per_day": 50, "features.x.enabled": false, …},
///      "features": {"round_video_from_gallery": false, …}}
///
/// `features` is the per-device result computed by the server (enabled, rollout_percent and
/// min_app_version already applied) and wins over `values`.
public struct LuckgramRemoteConfig {
    public let version: String?
    public let ttlSeconds: Double
    /// Seconds since 1970 when this response was received (for TTL refresh, S4).
    public let fetchedAt: Double
    private let values: [String: Any]
    private let features: [String: Any]

    public static let empty = LuckgramRemoteConfig(response: [:], fetchedAt: 0.0)

    /// Parses a server response. The server always sends the full set, so this replaces earlier values.
    public init(response: [String: Any], fetchedAt: Double) {
        var values = response["values"] as? [String: Any]
        let features = response["features"] as? [String: Any]
        if values == nil && features == nil {
            // Not the documented shape: treat it as a flat "key": value object.
            values = response
        }
        self.values = values ?? [:]
        self.features = features ?? [:]
        if let v = response["version"], !(v is NSNull) {
            self.version = "\(v)"
        } else {
            self.version = nil
        }
        self.ttlSeconds = max(0.0, (response["ttl"] as? NSNumber)?.doubleValue ?? 0.0)
        self.fetchedAt = fetchedAt
    }

    /// Whether the server allows the feature; true when the server says nothing about it.
    public func isAllowed(_ featureKey: String) -> Bool {
        if let value = LuckgramRemoteConfig.bool(self.features[featureKey]) {
            return value
        }
        if let value = LuckgramRemoteConfig.bool(self.values["features.\(featureKey).enabled"]) {
            return value
        }
        return true
    }

    /// A number from `values`, or `defaultValue` (the built-in default with the same name).
    public func int(_ key: String, default defaultValue: Int) -> Int {
        guard let number = self.values[key] as? NSNumber, !LuckgramRemoteConfig.isBool(number) else {
            return defaultValue
        }
        return number.intValue
    }

    public func string(_ key: String, default defaultValue: String?) -> String? {
        return (self.values[key] as? String) ?? defaultValue
    }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        return LuckgramRemoteConfig.bool(self.values[key]) ?? defaultValue
    }

    public func isExpired(now: Double) -> Bool {
        return self.fetchedAt == 0.0 || now - self.fetchedAt >= self.ttlSeconds
    }

    // JSONSerialization gives NSNumber for both numbers and booleans; tell them apart.
    private static func isBool(_ number: NSNumber) -> Bool {
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else {
            return nil
        }
        return number.boolValue
    }

    // MARK: - Persistence

    func serialized() -> Data? {
        var object: [String: Any] = ["ttl": self.ttlSeconds, "fetched_at": self.fetchedAt, "values": self.values, "features": self.features]
        if let version = self.version {
            object["version"] = version
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    init(serialized data: Data?) {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            self.init(response: [:], fetchedAt: 0.0)
            return
        }
        self.init(response: object, fetchedAt: (object["fetched_at"] as? NSNumber)?.doubleValue ?? 0.0)
    }
}
