import XCTest
@testable import LuckgramSharedActivity

/// Spec 16 (activity in shared groups): merge order, limit, cache, header wording.
final class LuckgramSharedActivityLogicTests: XCTestCase {
    private struct M {
        let date: Int32
        let id: Int64
    }

    private func merge(_ groups: [[M]], limit: Int = LuckgramSharedActivityLogic.maxItems) -> [M] {
        return LuckgramSharedActivityLogic.newestFirst(groups, limit: limit, date: { $0.date }, id: { $0.id })
    }

    func testMergesGroupsNewestFirst() {
        let merged = merge([
            [M(date: 300, id: 3), M(date: 100, id: 1)],
            [M(date: 250, id: 9)],
            [M(date: 400, id: 2), M(date: 50, id: 7)],
        ])
        XCTAssertEqual(merged.map { $0.date }, [400, 300, 250, 100, 50])
    }

    func testKeepsAtMostOneHundred() {
        var groups: [[M]] = []
        for g in 0 ..< 8 {
            groups.append((0 ..< LuckgramSharedActivityLogic.perGroup).map { M(date: Int32(g * 1000 + $0), id: Int64($0)) })
        }
        let merged = merge(groups)
        XCTAssertEqual(merged.count, 100)
        XCTAssertEqual(merged.first?.date, 7019)
        for i in 1 ..< merged.count {
            XCTAssertGreaterThanOrEqual(merged[i - 1].date, merged[i].date)
        }
    }

    func testSameDateHigherIdFirst() {
        XCTAssertEqual(merge([[M(date: 5, id: 1)], [], [M(date: 5, id: 2)]]).first?.id, 2)
    }

    func testCacheLastsTenMinutes() {
        let t = 1_000_000.0
        XCTAssertTrue(LuckgramSharedActivityLogic.isFresh(loadedAt: t, now: t + 9 * 60))
        XCTAssertFalse(LuckgramSharedActivityLogic.isFresh(loadedAt: t, now: t + 10 * 60))
        XCTAssertFalse(LuckgramSharedActivityLogic.isFresh(loadedAt: 0, now: t))
    }

    func testHeaderWording() {
        XCTAssertEqual(LuckgramSharedActivityLogic.header(groupCount: 3, chinese: true), "最近消息 · 3 个共同群组")
        XCTAssertEqual(LuckgramSharedActivityLogic.header(groupCount: 3, chinese: false), "Recent messages · 3 groups in common")
        XCTAssertEqual(LuckgramSharedActivityLogic.header(groupCount: 1, chinese: false), "Recent messages · 1 group in common")
    }
}
