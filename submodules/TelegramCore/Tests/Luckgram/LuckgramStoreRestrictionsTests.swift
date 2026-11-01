import XCTest
@testable import TelegramCore

/// Spec 13 验收：ios、android、ios-android、all、all 与 ios 并存 五种情况。
final class LuckgramStoreRestrictionsTests: XCTestCase {
    typealias S = LuckgramStoreRestrictions

    /// Mirrors Peer.restrictionText for the iOS app (`platform == "ios"`).
    private func firstText(_ rules: [(String, String)], switchOn: Bool) -> String? {
        for (platform, text) in rules {
            if S.ignore(platform, switchOn: switchOn) {
                continue
            }
            if platform == "all" || platform == "ios" {
                return text
            }
        }
        return nil
    }

    func testStoreOnlyPlatforms() {
        XCTAssertTrue(S.isStoreOnly("ios"))
        XCTAssertTrue(S.isStoreOnly("android"))
        XCTAssertTrue(S.isStoreOnly("ios-android"))
        XCTAssertTrue(S.isStoreOnly("IOS"))
        XCTAssertFalse(S.isStoreOnly("all"))
        XCTAssertFalse(S.isStoreOnly("ios-all"))
        XCTAssertFalse(S.isStoreOnly("windows"))
        XCTAssertFalse(S.isStoreOnly(""))
    }

    func testIosOnly() {
        XCTAssertEqual(firstText([("ios", "store rule")], switchOn: false), "store rule")
        XCTAssertNil(firstText([("ios", "store rule")], switchOn: true))
    }

    func testAndroidOnly() {
        XCTAssertTrue(S.ignore("android", switchOn: true))
        XCTAssertFalse(S.ignore("android", switchOn: false))
    }

    func testIosAndroid() {
        XCTAssertTrue(S.ignore("ios-android", switchOn: true))
        XCTAssertFalse(S.ignore("ios-android", switchOn: false))
    }

    func testAllStays() {
        XCTAssertEqual(firstText([("all", "banned")], switchOn: true), "banned")
        XCTAssertFalse(S.ignore("ios-all", switchOn: true))
    }

    func testAllTogetherWithIos() {
        let rules = [("ios", "store rule"), ("all", "banned")]
        XCTAssertEqual(firstText(rules, switchOn: false), "store rule")
        XCTAssertEqual(firstText(rules, switchOn: true), "banned")
    }

    func testGlobalSwitch() {
        let old = S.isEnabled
        defer { S.isEnabled = old }
        S.isEnabled = false
        XCTAssertFalse(S.ignore("ios"))
        S.isEnabled = true
        XCTAssertTrue(S.ignore("ios"))
        XCTAssertFalse(S.ignore("all"))
    }
}
