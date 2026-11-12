import Foundation

/// specs#87 (29): the Luckgram Pro state from `GET /v1/me`, as one value. Reads the S12 fields
/// (`pro{active,expires_at}`, `credits`, `perks`, `limits`) and falls back to the older `tier` /
/// `pro_expires_at`; anything missing counts as free. Cached as JSON so Pro still holds offline
/// until `expires_at`. Foundation only, unit tested on Linux; same rules as Android `ProState`.
public struct LuckgramProState: Equatable {
    // pro.perks values (S12); a perk missing from the list hides its row and feature.
    public static let perkAgentMarket = "agent_market"
    public static let perkAccounts = "accounts"
    public static let perkAI = "ai"
    public static let perkSummary = "summary"
    public static let perkTranslate = "translate"
    public static let perkCommunity = "community"
    public static let perkNoAds = "no_ads"

    /// Defaults when the server sends no `limits` (S12 §5).
    public static let accountsMaxFree = LuckgramAccountLimit.defaultMaxFree // 135
    public static let accountsMaxPro = LuckgramAccountLimit.slotCapacity
    public static let summaryMaxFree = 100
    public static let summaryMaxPro = 1000

    /// `pro.active` as sent by the server. Use `isPro(now:)`.
    public var active = false
    /// nil = unknown (then `active` alone decides).
    public var expiresAt: Date?
    public var creditsRemaining = 0
    public var creditsTotal = 0
    public var creditsResetsAt: Date?
    public var perks: [String] = []
    /// 0 = not sent; use `accountsMax(now:)` / `summaryMaxMessages(now:)`.
    var accountsMaxValue = 0
    var summaryMaxValue = 0
    /// When the server answered; nil for the free default. Not part of equality.
    public var fetchedAt: Date?

    public init() {
    }

    public static let free = LuckgramProState()

    /// Parses a `/v1/me` body. Never fails; `.free` for nil.
    public static func parse(_ me: [String: Any]?, now: Date) -> LuckgramProState {
        guard let me else {
            return .free
        }
        var s = LuckgramProState()
        if let pro = me["pro"] as? [String: Any] {
            s.active = pro["active"] as? Bool ?? false
            s.expiresAt = parseTime(pro["expires_at"] as? String)
        } else {
            s.active = (me["tier"] as? String) == "pro"
            s.expiresAt = parseTime(me["pro_expires_at"] as? String)
        }
        if let credits = me["credits"] as? [String: Any] {
            s.creditsRemaining = max(0, int(credits["remaining"]))
            s.creditsTotal = max(0, int(credits["total"]))
            s.creditsResetsAt = parseTime(credits["resets_at"] as? String)
        }
        for p in me["perks"] as? [Any] ?? [] {
            if let p = (p as? String)?.trimmingCharacters(in: .whitespaces), !p.isEmpty, !s.perks.contains(p) {
                s.perks.append(p)
            }
        }
        if let limits = me["limits"] as? [String: Any] {
            s.accountsMaxValue = max(0, int(limits["accounts_max"]))
            s.summaryMaxValue = max(0, int(limits["summary_max_messages"]))
        }
        s.fetchedAt = now
        return s
    }

    /// Pro applies now: the server said active and, when an expiry is known, it hasn't passed.
    public func isPro(now: Date) -> Bool {
        guard self.active else {
            return false
        }
        if let expiresAt = self.expiresAt {
            return now < expiresAt
        }
        return true
    }

    public func hasPerk(_ perk: String) -> Bool {
        return self.perks.contains(perk)
    }

    /// AI credits left this period; 0 when not Pro.
    public func credits(now: Date) -> Int {
        return self.isPro(now: now) ? self.creditsRemaining : 0
    }

    public func accountsMax(now: Date) -> Int {
        if self.accountsMaxValue > 0 {
            return self.accountsMaxValue
        }
        return self.isPro(now: now) ? LuckgramProState.accountsMaxPro : LuckgramProState.accountsMaxFree
    }

    public func summaryMaxMessages(now: Date) -> Int {
        if self.summaryMaxValue > 0 {
            return self.summaryMaxValue
        }
        return self.isPro(now: now) ? LuckgramProState.summaryMaxPro : LuckgramProState.summaryMaxFree
    }

    /// Equal when everything a user would see is equal (the fetch time is ignored).
    public static func == (a: LuckgramProState, b: LuckgramProState) -> Bool {
        return a.active == b.active && a.expiresAt == b.expiresAt && a.creditsRemaining == b.creditsRemaining
            && a.creditsTotal == b.creditsTotal && a.creditsResetsAt == b.creditsResetsAt && a.perks == b.perks
            && a.accountsMaxValue == b.accountsMaxValue && a.summaryMaxValue == b.summaryMaxValue
    }

    // MARK: - Cache

    public func toCache() -> String? {
        var j: [String: Any] = [
            "active": self.active,
            "credits_remaining": self.creditsRemaining,
            "credits_total": self.creditsTotal,
            "perks": self.perks,
            "accounts_max": self.accountsMaxValue,
            "summary_max_messages": self.summaryMaxValue
        ]
        for (key, value) in [("expires_at_ms", self.expiresAt), ("credits_resets_at_ms", self.creditsResetsAt), ("fetched_at_ms", self.fetchedAt)] {
            if let value {
                j[key] = NSNumber(value: Int64(value.timeIntervalSince1970 * 1000))
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: j) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Reads `toCache()`; `.free` for nil or anything unreadable.
    public static func fromCache(_ s: String?) -> LuckgramProState {
        guard let s, let data = s.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .free
        }
        func date(_ key: String) -> Date? {
            let ms = (j[key] as? NSNumber)?.int64Value ?? 0
            return ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000.0) : nil
        }
        var st = LuckgramProState()
        st.active = j["active"] as? Bool ?? false
        st.expiresAt = date("expires_at_ms")
        st.creditsRemaining = max(0, int(j["credits_remaining"]))
        st.creditsTotal = max(0, int(j["credits_total"]))
        st.creditsResetsAt = date("credits_resets_at_ms")
        st.perks = (j["perks"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        st.accountsMaxValue = max(0, int(j["accounts_max"]))
        st.summaryMaxValue = max(0, int(j["summary_max_messages"]))
        st.fetchedAt = date("fetched_at_ms")
        return st
    }

    // MARK: - Helpers

    static func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber {
            return n.intValue
        }
        if let i = v as? Int {
            return i
        }
        return 0
    }

    static func parseTime(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else {
            return nil
        }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) {
            return d
        }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
