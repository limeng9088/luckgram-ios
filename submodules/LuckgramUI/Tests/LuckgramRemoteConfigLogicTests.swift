import XCTest
import LuckgramUI

/// Task S4, app side.
final class LuckgramRemoteConfigLogicTests: XCTestCase {
    typealias L = LuckgramRemoteConfigLogic
    let h = 3600.0

    func testNeverFetchedIsStale() {
        XCTAssertTrue(L.isStale(now: 10 * h, fetchedAt: 0, ttlSeconds: 3600, lastFailure: 0))
    }

    func testRefreshesOnlyAfterTTL() {
        let fetched = 100 * h
        XCTAssertFalse(L.isStale(now: fetched + 59 * 60, fetchedAt: fetched, ttlSeconds: 3600, lastFailure: 0))
        XCTAssertTrue(L.isStale(now: fetched + h, fetchedAt: fetched, ttlSeconds: 3600, lastFailure: 0))
        // 验收：TTL 调小后（测试用）按新 TTL 刷新
        XCTAssertTrue(L.isStale(now: fetched + 61, fetchedAt: fetched, ttlSeconds: 60, lastFailure: 0))
        XCTAssertFalse(L.isStale(now: fetched + 1, fetchedAt: fetched, ttlSeconds: 0, lastFailure: 0))
        XCTAssertTrue(L.isStale(now: fetched - 1, fetchedAt: fetched, ttlSeconds: 3600, lastFailure: 0))
    }

    func testFailureBacksOffButKeepsCache() {
        let fetched = 100 * h, failed = fetched + 2 * h
        XCTAssertFalse(L.isStale(now: failed + 60, fetchedAt: fetched, ttlSeconds: 3600, lastFailure: failed))
        XCTAssertTrue(L.isStale(now: failed + L.retryAfterFailureSeconds, fetchedAt: fetched, ttlSeconds: 3600, lastFailure: failed))
    }
}
