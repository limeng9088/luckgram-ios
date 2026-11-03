import XCTest
@testable import LuckgramUI

final class LuckgramCloudBackupLogicTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    func testUploadBodyCarriesOnlyCiphertextAndCounters() {
        let body = LuckgramCloudBackupLogic.uploadBody(dataBase64: "ZW5jcnlwdGVk", accounts: 3, createdAt: 1762135200)
        XCTAssertEqual(body["data"] as? String, "ZW5jcnlwdGVk")
        XCTAssertEqual(body["accounts"] as? Int, 3)
        XCTAssertEqual(body["created_at"] as? String, "2025-11-03T02:00:00Z")
        XCTAssertEqual(body["format_version"] as? Int, 1)
        XCTAssertEqual(body.count, 4)
    }

    func testParseMeta() {
        let meta = LuckgramCloudBackupLogic.parseMeta(["backup": ["accounts": 2, "created_at": "2025-11-03T02:00:00Z", "format_version": 1, "data": "QUJD"]])
        XCTAssertEqual(meta, LuckgramCloudBackupLogic.Meta(accounts: 2, createdAt: 1762135200, data: "QUJD"))

        let bare = LuckgramCloudBackupLogic.parseMeta(["accounts": 1, "uploaded_at": "2025-11-03T02:00:00.123Z"])
        XCTAssertEqual(bare?.accounts, 1)
        XCTAssertEqual(bare?.createdAt ?? 0, 1762135200.123, accuracy: 0.001)
        XCTAssertNil(bare?.data)

        XCTAssertNil(LuckgramCloudBackupLogic.parseMeta(["backup": NSNull()]))
        XCTAssertNil(LuckgramCloudBackupLogic.parseMeta([:]))
        XCTAssertNil(LuckgramCloudBackupLogic.parseMeta(nil))
    }

    func testNotFound() {
        XCTAssertTrue(LuckgramCloudBackupLogic.isNotFound(code: "not_found", httpStatus: 404))
        XCTAssertTrue(LuckgramCloudBackupLogic.isNotFound(code: "whatever", httpStatus: 404))
        XCTAssertFalse(LuckgramCloudBackupLogic.isNotFound(code: "not_pro", httpStatus: 403))
    }

    func testAutoBackupNeedsSwitchAndRememberedPassword() {
        let now = 1000 * day
        XCTAssertFalse(LuckgramCloudBackupLogic.autoBackupDue(enabled: false, passwordRemembered: true, last: 0, now: now))
        XCTAssertFalse(LuckgramCloudBackupLogic.autoBackupDue(enabled: true, passwordRemembered: false, last: 0, now: now))
        XCTAssertTrue(LuckgramCloudBackupLogic.autoBackupDue(enabled: true, passwordRemembered: true, last: 0, now: now))
        XCTAssertFalse(LuckgramCloudBackupLogic.autoBackupDue(enabled: true, passwordRemembered: true, last: now - 6 * day, now: now))
        XCTAssertTrue(LuckgramCloudBackupLogic.autoBackupDue(enabled: true, passwordRemembered: true, last: now - 7 * day, now: now))
        XCTAssertTrue(LuckgramCloudBackupLogic.autoBackupDue(enabled: true, passwordRemembered: true, last: now + day, now: now))
    }

    func testBadDatesAreZero() {
        XCTAssertEqual(LuckgramCloudBackupLogic.parseRFC3339(""), 0)
        XCTAssertEqual(LuckgramCloudBackupLogic.parseRFC3339("yesterday"), 0)
    }
}
