import XCTest
@testable import LuckgramUI

final class LuckgramAccountLogicTests: XCTestCase {
    func testParsesLinkStatus() {
        let s = LuckgramAccountLogic.parseLink(["linked": true, "devices": 2, "max_devices": 5, "request": "linked"])
        XCTAssertTrue(s.linked)
        XCTAssertEqual(s.devices, 2)
        XCTAssertEqual(s.maxDevices, 5)
        XCTAssertEqual(s.request, "linked")
        XCTAssertNil(LuckgramAccountLogic.parseLink(["linked": false, "devices": 0, "max_devices": 5]).request)
    }

    func testPollsOnlyWhilePendingAndUnexpired() {
        let exp = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(LuckgramAccountLogic.shouldPoll(request: "pending", now: exp.addingTimeInterval(-1), expiresAt: exp))
        XCTAssertTrue(LuckgramAccountLogic.shouldPoll(request: nil, now: exp.addingTimeInterval(-1), expiresAt: exp))
        XCTAssertFalse(LuckgramAccountLogic.shouldPoll(request: "pending", now: exp, expiresAt: exp))
        for done in ["linked", "expired", "used", "limit_reached"] {
            XCTAssertFalse(LuckgramAccountLogic.shouldPoll(request: done, now: Date(timeIntervalSince1970: 0), expiresAt: exp), done)
        }
    }

    func testParsesStartAndTimes() {
        let st = LuckgramAccountLogic.parseStart(["nonce": "abc", "url": "https://t.me/LuckgramBot?start=abc", "expires_at": "2026-11-01T00:10:00Z"])
        XCTAssertEqual(st.expiresAt?.timeIntervalSince1970, 1793491800)
        XCTAssertTrue(LuckgramAccountLogic.isTelegramLink(st.url))
        XCTAssertFalse(LuckgramAccountLogic.isTelegramLink("https://evil.example/t.me/x"))
        XCTAssertFalse(LuckgramAccountLogic.isTelegramLink("https://t.me/"))
        XCTAssertEqual(LuckgramAccountLogic.parseTime("2026-11-01T08:10:00+08:00"), st.expiresAt)
        XCTAssertEqual(LuckgramAccountLogic.parseTime("2026-11-01T00:10:00.123Z")?.timeIntervalSince1970 ?? 0, 1793491800.123, accuracy: 0.001)
        XCTAssertNil(LuckgramAccountLogic.parseTime("garbage"))
        XCTAssertEqual(LuckgramAccountLogic.date("2026-10-31T16:30:00Z", timeZone: TimeZone(identifier: "Asia/Shanghai")!), "2026-11-01")
        XCTAssertEqual(LuckgramAccountLogic.date("2026-10-31T16:30:00Z", timeZone: TimeZone(identifier: "UTC")!), "2026-10-31")
    }

    func testParsesBillingAndHidesFreePlans() {
        let b = LuckgramAccountLogic.parseBilling(["enabled": true, "linked": true, "tier": "pro", "pro_expires_at": "2026-12-01T00:00:00Z",
                                                   "plans": [["id": "pro_month", "days": 30, "stars": 100], ["id": "x", "days": 1, "stars": 0]]])
        XCTAssertTrue(b.enabled && b.pro)
        XCTAssertEqual(b.proExpiresAt, "2026-12-01T00:00:00Z")
        XCTAssertEqual(b.plans, [LuckgramAccountLogic.Plan(id: "pro_month", days: 30, stars: 100)])
        let free = LuckgramAccountLogic.parseBilling(["enabled": false, "linked": false, "plans": [], "tier": "free", "pro_expires_at": NSNull()])
        XCTAssertFalse(free.pro)
        XCTAssertNil(free.proExpiresAt)
    }

    func testTextsInBothLanguages() {
        let zh = LuckgramAccountLogic.Texts(zh: true), en = LuckgramAccountLogic.Texts(zh: false)
        XCTAssertTrue(zh.linkResult("limit_reached", max: 5).contains("5 台"))
        XCTAssertTrue(en.linkResult("limit_reached", max: 5).contains("5 linked"))
        for code in ["link_unavailable", "already_linked", "not_linked", "billing_disabled", "rate_limited", "network_error", "x", nil] as [String?] {
            XCTAssertFalse(zh.error(code).isEmpty)
            XCTAssertFalse(en.error(code).isEmpty)
        }
        XCTAssertEqual(zh.proUntil("2026-12-01"), "Pro，到期 2026-12-01")
    }
}
