import XCTest
@testable import LuckgramProfileInfo

/// Spec 07 (profile details): ID format, registration-date estimate, strings.
final class LuckgramProfileInfoLogicTests: XCTestCase {
    private func bundledTable() throws -> [LuckgramProfileInfoLogic.Point] {
        // The CI step copies the resource next to the package (TABLE_PATH).
        let path = ProcessInfo.processInfo.environment["TABLE_PATH"] ?? "LuckgramRegistrationDates.txt"
        return LuckgramProfileInfoLogic.parseTable(try String(contentsOfFile: path, encoding: .utf8))
    }

    // 需求 1：ID

    func testIdFormats() {
        XCTAssertEqual(LuckgramProfileInfoLogic.displayId(.user, id: 777000), "777000")
        XCTAssertEqual(LuckgramProfileInfoLogic.displayId(.channel, id: 1234567890), "-1001234567890")
        XCTAssertEqual(LuckgramProfileInfoLogic.displayId(.legacyGroup, id: 123456), "-123456")
    }

    func testOnlyUsersHaveATgLink() {
        XCTAssertEqual(LuckgramProfileInfoLogic.userLink(.user, id: 42), "tg://user?id=42")
        XCTAssertNil(LuckgramProfileInfoLogic.userLink(.channel, id: 42))
        XCTAssertNil(LuckgramProfileInfoLogic.userLink(.legacyGroup, id: 42))
    }

    // 需求 2：注册时间

    func testBundledTableCovers2013ToRecentYearsQuarterly() throws {
        let t = try bundledTable()
        XCTAssertGreaterThanOrEqual(t.count, 45)
        XCTAssertEqual(t[0].monthIndex / 12, 2013)
        XCTAssertGreaterThanOrEqual(t[t.count - 1].monthIndex / 12, 2026)
        for i in 1 ..< t.count {
            XCTAssertGreaterThan(t[i].id, t[i - 1].id)
            XCTAssertLessThanOrEqual(t[i].monthIndex - t[i - 1].monthIndex, 3)
        }
    }

    func testKnownAccountsAreWithinSixMonths() throws {
        let t = try bundledTable()
        let known: [(Int64, Int, Int)] = [
            (101323197, 2015, 3), (369669043, 2017, 3), (805158066, 2019, 7), (1974255900, 2021, 10),
            (5144324763, 2022, 4), (6872061796, 2024, 5), (8325327280, 2025, 10), (8559682245, 2025, 11),
        ]
        for (id, year, month) in known {
            guard case let .month(y, m)? = LuckgramProfileInfoLogic.estimate(t, userId: id) else {
                XCTFail("no estimate for \(id)")
                continue
            }
            XCTAssertLessThanOrEqual(abs((y * 12 + m) - (year * 12 + month)), 6, "\(id) -> \(y)-\(m)")
        }
    }

    func testVeryOldIdsAreBefore2014() throws {
        let e = LuckgramProfileInfoLogic.estimate(try bundledTable(), userId: 1000)
        XCTAssertEqual(e, .before2014)
        XCTAssertEqual(LuckgramProfileInfoLogic.format(.before2014, chinese: true), "早于 2014 年")
        XCTAssertEqual(LuckgramProfileInfoLogic.format(.before2014, chinese: false), "before 2014")
    }

    func testIdsNewerThanTheTableAreNotGuessed() throws {
        XCTAssertNil(LuckgramProfileInfoLogic.estimate(try bundledTable(), userId: 9_900_000_000))
        XCTAssertNil(LuckgramProfileInfoLogic.estimate(try bundledTable(), userId: 0))
        XCTAssertNil(LuckgramProfileInfoLogic.estimate([], userId: 805158066))
    }

    func testFormatAlwaysSaysApproximately() {
        let e = LuckgramProfileInfoLogic.estimate(LuckgramProfileInfoLogic.parseTable("100,2019-01\n200,2020-01\n"), userId: 175)
        XCTAssertEqual(e, .month(year: 2019, month: 10))
        XCTAssertEqual(LuckgramProfileInfoLogic.format(e!, chinese: true), "约 2019 年 10 月")
        XCTAssertEqual(LuckgramProfileInfoLogic.format(e!, chinese: false), "about Oct 2019")
    }

    func testMalformedAndOutOfOrderLinesAreSkipped() {
        let t = LuckgramProfileInfoLogic.parseTable("# c\n\n100,2019-01\nx,2019-02\n90,2019-03\n150,2018-01\n200,2019-13\n300,2020-01\n")
        XCTAssertEqual(t.count, 2)
    }
}
