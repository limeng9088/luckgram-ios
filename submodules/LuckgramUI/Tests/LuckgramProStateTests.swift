import XCTest
import LuckgramUI

/// specs#87 (29): one Pro state from /v1/me; S12 fields, older fields, missing = free, offline cache.
final class LuckgramProStateTests: XCTestCase {
    private func t(_ s: String) -> Date {
        return ISO8601DateFormatter().date(from: s)!
    }

    private var now: Date {
        return t("2026-11-03T00:00:00Z")
    }

    func testS12Fields() {
        let me: [String: Any] = [
            "pro": ["active": true, "expires_at": "2026-12-03T00:00:00Z"],
            "credits": ["remaining": 37, "total": 50, "resets_at": "2026-12-01T00:00:00Z"],
            "perks": ["ai", "no_ads", "summary", "ai", ""],
            "limits": ["accounts_max": 50, "summary_max_messages": 1000]
        ]
        let s = LuckgramProState.parse(me, now: now)
        XCTAssertTrue(s.isPro(now: now))
        XCTAssertEqual(s.credits(now: now), 37)
        XCTAssertEqual(s.creditsTotal, 50)
        XCTAssertEqual(s.creditsResetsAt, t("2026-12-01T00:00:00Z"))
        XCTAssertEqual(s.perks, ["ai", "no_ads", "summary"])
        XCTAssertTrue(s.hasPerk(LuckgramProState.perkNoAds))
        XCTAssertFalse(s.hasPerk(LuckgramProState.perkAgentMarket))
        XCTAssertEqual(s.accountsMax(now: now), 50)
        XCTAssertEqual(s.summaryMaxMessages(now: now), 1000)
    }

    func testOlderTierFields() {
        let s = LuckgramProState.parse(["tier": "pro", "pro_expires_at": "2026-11-10T00:00:00Z"], now: now)
        XCTAssertTrue(s.isPro(now: now))
        XCTAssertFalse(s.isPro(now: t("2026-11-10T00:00:01Z")))
        XCTAssertFalse(LuckgramProState.parse(["tier": "free", "pro_expires_at": NSNull()], now: now).isPro(now: now))
    }

    func testMissingFieldsAreFree() {
        let s = LuckgramProState.parse(["quota": [String: Any]()], now: now)
        XCTAssertFalse(s.isPro(now: now))
        XCTAssertEqual(s.credits(now: now), 0)
        XCTAssertTrue(s.perks.isEmpty)
        XCTAssertEqual(s.accountsMax(now: now), LuckgramProState.accountsMaxFree)
        XCTAssertEqual(s.summaryMaxMessages(now: now), LuckgramProState.summaryMaxFree)
        XCTAssertFalse(LuckgramProState.parse(nil, now: now).isPro(now: now))
        XCTAssertFalse(LuckgramProState.free.isPro(now: now))
    }

    func testExpiredOrInactiveIsFree() {
        let expired = LuckgramProState.parse(["pro": ["active": true, "expires_at": "2026-11-01T00:00:00Z"], "credits": ["remaining": 5]], now: now)
        XCTAssertFalse(expired.isPro(now: now))
        XCTAssertEqual(expired.credits(now: now), 0)
        XCTAssertEqual(expired.summaryMaxMessages(now: now), LuckgramProState.summaryMaxFree)
        XCTAssertFalse(LuckgramProState.parse(["pro": ["active": false, "expires_at": "2027-01-01T00:00:00Z"]], now: now).isPro(now: now))
        // active without a known expiry: the server's word decides; Pro defaults without limits
        let open = LuckgramProState.parse(["pro": ["active": true]], now: now)
        XCTAssertTrue(open.isPro(now: now))
        XCTAssertEqual(open.accountsMax(now: now), LuckgramProState.accountsMaxPro)
    }

    func testCacheKeepsProOfflineUntilExpiry() {
        let s = LuckgramProState.parse([
            "pro": ["active": true, "expires_at": "2026-11-20T00:00:00Z"],
            "credits": ["remaining": 3, "total": 50],
            "perks": ["ai"],
            "limits": ["summary_max_messages": 500]
        ], now: now)
        let c = LuckgramProState.fromCache(s.toCache())
        XCTAssertEqual(c, s)
        XCTAssertTrue(c.isPro(now: now))
        XCTAssertEqual(c.summaryMaxMessages(now: now), 500)
        XCTAssertEqual(c.fetchedAt, now)
        XCTAssertFalse(c.isPro(now: t("2026-11-20T00:00:00Z")))
        XCTAssertFalse(LuckgramProState.fromCache(nil).isPro(now: now))
        XCTAssertFalse(LuckgramProState.fromCache("not json").isPro(now: now))
    }

    func testChangeDetection() {
        let a = LuckgramProState.parse(["pro": ["active": true], "credits": ["remaining": 3]], now: now)
        let b = LuckgramProState.parse(["pro": ["active": true], "credits": ["remaining": 2]], now: now.addingTimeInterval(1))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, LuckgramProState.parse(["pro": ["active": true], "credits": ["remaining": 3]], now: now.addingTimeInterval(5)))
    }
}
