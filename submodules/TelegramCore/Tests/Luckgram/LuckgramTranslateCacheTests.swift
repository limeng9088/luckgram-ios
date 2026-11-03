import XCTest
@testable import TelegramCore

/// spec 01 「翻译服务」5：最多 2000 条、7 天；同一文字同一目标语言读缓存。
final class LuckgramTranslateCacheTests: XCTestCase {
    typealias C = LuckgramTranslateCache
    let day: TimeInterval = 24 * 60 * 60

    func testKeyDependsOnLanguageAndTextAndHidesText() {
        let k = C.key(toLang: "zh", text: "Hello")
        XCTAssertEqual(k, C.key(toLang: "zh", text: "Hello"))
        XCTAssertNotEqual(k, C.key(toLang: "en", text: "Hello"))
        XCTAssertNotEqual(k, C.key(toLang: "zh", text: "Hello!"))
        XCTAssertEqual(k.count, 32)
        XCTAssertFalse(k.contains("Hello"))
    }

    func testHitWithinSevenDaysMissAfter() {
        let c = C()
        let k = C.key(toLang: "zh", text: "Hello")
        c.put(k, text: "你好", fromLang: "en", now: 1000)
        XCTAssertEqual(c.get(k, now: 1000 + 6 * day)?.text, "你好")
        XCTAssertEqual(c.get(k, now: 1000 + 6 * day)?.fromLang, "en")
        XCTAssertNil(c.get(k, now: 1000 + 7 * day + 1))
        XCTAssertEqual(c.count, 0)
    }

    func testKeepsAtMostMaxEntriesDroppingLeastRecentlyUsed() {
        let c = C(maxEntries: 3)
        c.put("a", text: "A", fromLang: nil, now: 1)
        c.put("b", text: "B", fromLang: nil, now: 2)
        c.put("c", text: "C", fromLang: nil, now: 3)
        XCTAssertNotNil(c.get("a", now: 4))
        c.put("d", text: "D", fromLang: nil, now: 5)
        XCTAssertEqual(c.count, 3)
        XCTAssertNil(c.get("b", now: 6))
        XCTAssertNotNil(c.get("a", now: 6))
        XCTAssertNotNil(c.get("d", now: 6))
    }

    func testDefaultLimitIs2000() {
        let c = C()
        for i in 0 ..< 2100 {
            c.put("k\(i)", text: "v\(i)", fromLang: nil, now: Double(i))
        }
        XCTAssertEqual(c.count, C.maxEntries)
        XCTAssertNil(c.get("k0", now: 3000))
        XCTAssertNotNil(c.get("k2099", now: 3000))
    }

    func testIgnoresEmptyResults() {
        let c = C()
        c.put("k", text: "", fromLang: nil, now: 1)
        XCTAssertEqual(c.count, 0)
    }

    func testSerializeRoundTripSkipsExpired() {
        let c = C()
        c.put("old", text: "旧", fromLang: nil, now: 0)
        c.put("new", text: "新", fromLang: "en", now: 8 * day)
        let r = C.parse(c.serialize(now: 8 * day + 1), now: 8 * day + 1)
        XCTAssertNil(r.get("old", now: 8 * day + 1))
        XCTAssertEqual(r.get("new", now: 8 * day + 1)?.text, "新")
        XCTAssertEqual(r.get("new", now: 8 * day + 1)?.fromLang, "en")
        XCTAssertEqual(C.parse(Data("not json".utf8), now: 0).count, 0)
        XCTAssertEqual(C.parse(nil, now: 0).count, 0)
    }
}
