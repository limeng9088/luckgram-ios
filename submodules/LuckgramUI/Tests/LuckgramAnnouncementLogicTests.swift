import XCTest
@testable import LuckgramUI

final class LuckgramAnnouncementLogicTests: XCTestCase {
    private let response: [String: Any] = ["announcements": [
        ["id": "a1", "title": "新版本", "body": "去更新", "url": "https://luckgram.cc/x", "priority": 50, "starts_at": "2026-11-01T00:00:00Z", "ends_at": "2026-11-02T00:00:00Z"],
        ["id": "a2", "title": "第二条", "body": "", "url": "javascript:alert(1)", "priority": 10, "ends_at": "2026-11-03T00:00:00Z"],
        ["id": "", "title": "no id"],
        ["id": "a3", "title": ""],
    ]]

    func testParsesAndDropsBadEntries() {
        let items = LuckgramAnnouncementLogic.parse(self.response)
        XCTAssertEqual(items.map(\.id), ["a1", "a2"])
        XCTAssertEqual(items[0].url, "https://luckgram.cc/x")
        XCTAssertEqual(items[1].url, "") // only https links are opened
        XCTAssertTrue(LuckgramAnnouncementLogic.parse([:]).isEmpty)
    }

    func testPicksFirstOpenAndUnexpired() {
        let items = LuckgramAnnouncementLogic.parse(self.response)
        let nov1 = Date(timeIntervalSince1970: 1793491200)
        XCTAssertEqual(LuckgramAnnouncementLogic.pick(items, dismissed: [], now: nov1)?.id, "a1")
        XCTAssertEqual(LuckgramAnnouncementLogic.pick(items, dismissed: ["a1"], now: nov1)?.id, "a2")
        // a1 ends at 2026-11-02T00:00Z: gone at that instant even without a new fetch.
        XCTAssertEqual(LuckgramAnnouncementLogic.pick(items, dismissed: [], now: nov1.addingTimeInterval(86400))?.id, "a2")
        XCTAssertNil(LuckgramAnnouncementLogic.pick(items, dismissed: ["a1", "a2"], now: nov1))
    }

    func testDismissedListIsCappedAndRoundTrips() {
        var d: [String] = []
        for i in 0 ..< 60 {
            d = LuckgramAnnouncementLogic.dismiss(d, "id\(i)")
        }
        XCTAssertEqual(d.count, LuckgramAnnouncementLogic.maxDismissed)
        XCTAssertEqual(d.first, "id10")
        d = LuckgramAnnouncementLogic.dismiss(d, "id10")
        XCTAssertEqual(d.last, "id10")
        XCTAssertEqual(LuckgramAnnouncementLogic.parseDismissed(LuckgramAnnouncementLogic.serializeDismissed(d)), d)
        XCTAssertTrue(LuckgramAnnouncementLogic.parseDismissed("garbage").isEmpty)
        XCTAssertTrue(LuckgramAnnouncementLogic.parseDismissed(nil).isEmpty)
    }

    func testRefreshSchedule() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        XCTAssertTrue(LuckgramAnnouncementLogic.shouldRefresh(now: now, lastSuccess: nil, lastFailure: nil))
        XCTAssertFalse(LuckgramAnnouncementLogic.shouldRefresh(now: now, lastSuccess: now.addingTimeInterval(-60), lastFailure: nil))
        XCTAssertTrue(LuckgramAnnouncementLogic.shouldRefresh(now: now, lastSuccess: now.addingTimeInterval(-LuckgramAnnouncementLogic.refreshInterval), lastFailure: nil))
        XCTAssertFalse(LuckgramAnnouncementLogic.shouldRefresh(now: now, lastSuccess: nil, lastFailure: now.addingTimeInterval(-60)))
        XCTAssertTrue(LuckgramAnnouncementLogic.shouldRefresh(now: now, lastSuccess: nil, lastFailure: now.addingTimeInterval(-LuckgramAnnouncementLogic.retryAfterFailure)))
    }
}
