import XCTest
@testable import LuckgramUI

/// specs#117: whoami parsing and the "🇸🇬 Singapore · 1.2.3.4" label.
final class LuckgramProxyExitLogicTests: XCTestCase {
    func testParsesWhoami() {
        let e = LuckgramProxyExit.parse(Data("{\"ip\":\"45.39.75.124\",\"country\":\"sg\",\"city\":\"Singapore\"}".utf8))
        XCTAssertEqual(e?.ip, "45.39.75.124")
        XCTAssertEqual(e?.country, "SG")
        XCTAssertEqual(e?.city, "Singapore")
    }

    func testRejectsJunk() {
        XCTAssertNil(LuckgramProxyExit.parse(Data("not json".utf8)))
        XCTAssertNil(LuckgramProxyExit.parse(Data("{\"country\":\"SG\"}".utf8)))
        XCTAssertEqual(LuckgramProxyExit.parse(Data("{\"ip\":\"1.2.3.4\",\"country\":\"XX\"}".utf8))?.country, "")
        XCTAssertEqual(LuckgramProxyExit.parse(Data("{\"ip\":\"1.2.3.4\",\"country\":\"USA\"}".utf8))?.country, "")
    }

    func testFlag() {
        XCTAssertEqual(LuckgramProxyExit.flag("SG"), "\u{1F1F8}\u{1F1EC}")
        XCTAssertEqual(LuckgramProxyExit.flag("US"), "\u{1F1FA}\u{1F1F8}")
        XCTAssertEqual(LuckgramProxyExit.flag(""), "")
        XCTAssertEqual(LuckgramProxyExit.flag("sg"), "")
    }

    func testLabel() {
        let e = LuckgramProxyExit(ip: "45.39.75.124", country: "SG", city: "")
        XCTAssertEqual(e.label(countryName: { _ in "新加坡" }), "\u{1F1F8}\u{1F1EC} 新加坡 · 45.39.75.124")
        XCTAssertEqual(e.label(countryName: { _ in nil }), "\u{1F1F8}\u{1F1EC} SG · 45.39.75.124")
        XCTAssertEqual(LuckgramProxyExit(ip: "1.2.3.4", country: "", city: "").label(countryName: { _ in "x" }), "1.2.3.4")
    }

    func testFreshForTenMinutes() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(LuckgramProxyExit.isFresh(checkedAt: t, now: t.addingTimeInterval(LuckgramProxyExit.ttl - 1)))
        XCTAssertFalse(LuckgramProxyExit.isFresh(checkedAt: t, now: t.addingTimeInterval(LuckgramProxyExit.ttl)))
        XCTAssertFalse(LuckgramProxyExit.isFresh(checkedAt: nil, now: t))
        XCTAssertFalse(LuckgramProxyExit.isFresh(checkedAt: t, now: t.addingTimeInterval(-5)))
    }

    func testTexts() {
        XCTAssertEqual(LuckgramProxyExitTexts(zh: true).directTitle, "直连（不使用代理）")
        XCTAssertEqual(LuckgramProxyExitTexts(zh: false).failed, "Exit check failed")
    }
}
