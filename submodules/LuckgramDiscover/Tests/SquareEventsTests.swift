import XCTest
@testable import LuckgramDiscover

/// luckgram-specs#115: same cases as Android SquareEventsTest.
final class SquareEventsTests: XCTestCase {
    func testImpressionsOncePerLoadAndViews() {
        let t = SquareEvents.Tracker(tab: "recommend")
        var e = t.update(visible: ["a": 0, "b": 1], now: 1000)
        XCTAssertEqual(e.map { $0.type }, ["impression", "impression"])
        XCTAssertTrue(t.update(visible: ["a": 0, "b": 1], now: 2000).isEmpty)
        e = t.update(visible: ["b": 1], now: 4500)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].type, "view")
        XCTAssertEqual(e[0].postId, "a")
        XCTAssertEqual(e[0].dwellMs, 3500)
        XCTAssertEqual(e[0].rank, 0)
        XCTAssertTrue(t.update(visible: ["a": 0, "b": 1], now: 5000).isEmpty)
        XCTAssertEqual(t.hideAll(now: 5600).count, 2)
        XCTAssertEqual(SquareEvents.Tracker(tab: "hot").update(visible: ["a": 0], now: 0).count, 1)
    }

    func testDwellIsCapped() {
        let t = SquareEvents.Tracker(tab: "hot")
        _ = t.update(visible: ["a": 0], now: 0)
        XCTAssertEqual(t.hideAll(now: 60 * 60 * 1000).first?.dwellMs, SquareEvents.maxDwellMs)
    }

    func testJsonHasOnlyContractFields() {
        let o = SquareEvents.Event(type: "view", postId: "p1", tab: "recommend", rank: 3, dwellMs: 5400, timeMs: 0).json
        XCTAssertEqual(o["type"] as? String, "view")
        XCTAssertEqual(o["post_id"] as? String, "p1")
        XCTAssertEqual(o["tab"] as? String, "recommend")
        XCTAssertEqual(o["rank"] as? Int, 3)
        XCTAssertEqual(o["dwell_ms"] as? Int64, 5400)
        XCTAssertEqual(o["at"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(o.count, 6)
        let open = SquareEvents.Event(type: "open", postId: "p1", tab: "hot", timeMs: 0).json
        XCTAssertNil(open["dwell_ms"])
        XCTAssertNil(open["rank"])
    }

    func testQueueBatchesAndPersists() {
        let now: Int64 = 1_800_000_000_000
        let q = SquareEvents.Queue(stored: nil, now: now)
        XCTAssertFalse(q.shouldFlush(now: now))
        q.add((0 ..< 19).map { SquareEvents.Event(type: "open", postId: "p\($0)", tab: "latest", timeMs: now) })
        XCTAssertFalse(q.shouldFlush(now: now + 1000))
        XCTAssertTrue(q.shouldFlush(now: now + SquareEvents.flushIntervalMs))
        q.add([SquareEvents.Event(type: "open", postId: "p19", tab: "latest", timeMs: now)])
        XCTAssertTrue(q.shouldFlush(now: now + 1000))
        q.add((0 ..< 200).map { SquareEvents.Event(type: "open", postId: "x\($0)", tab: "latest", timeMs: now) })
        let batch = q.nextBatch()!
        XCTAssertEqual(batch.count, SquareEvents.batchMax)
        q.onSent(count: batch.count, now: now)
        XCTAssertEqual(q.count, 120)
        XCTAssertEqual(SquareEvents.Queue(stored: q.encoded(), now: now + 1000).count, 120)
        XCTAssertEqual(SquareEvents.Queue(stored: q.encoded(), now: now + SquareEvents.maxAgeMs + 1).count, 0)
        XCTAssertNil(SquareEvents.Queue(stored: "garbage", now: now).nextBatch())
    }

    func testRetryOnceThenDrop() {
        let q = SquareEvents.Queue(stored: nil, now: 0)
        q.add([SquareEvents.Event(type: "open", postId: "a", tab: "latest", timeMs: 0)])
        q.onFailed(count: 1, httpStatus: 0, now: 0)
        XCTAssertEqual(q.count, 1)
        q.onFailed(count: 1, httpStatus: 503, now: 0)
        XCTAssertEqual(q.count, 0)
        q.add([SquareEvents.Event(type: "open", postId: "b", tab: "latest", timeMs: 0)])
        q.onFailed(count: 1, httpStatus: 400, now: 0)
        XCTAssertEqual(q.count, 0)
    }

    func testQueueCap() {
        let q = SquareEvents.Queue(stored: nil, now: 0)
        q.add((0 ..< SquareEvents.queueMax + 10).map { SquareEvents.Event(type: "open", postId: "p\($0)", tab: "latest", timeMs: 0) })
        XCTAssertEqual(q.count, SquareEvents.queueMax)
    }

    func testRecommendFeedPath() {
        XCTAssertEqual(SquareLogic.feedPath(tab: SquareLogic.tabRecommend, cursor: nil), "/v1/square/feed?tab=recommend")
    }
}
