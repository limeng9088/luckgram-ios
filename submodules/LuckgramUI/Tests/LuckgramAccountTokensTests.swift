import XCTest
@testable import LuckgramUI

final class LuckgramAccountTokensTests: XCTestCase {
    func testOneKeychainAccountPerTelegramUser() {
        XCTAssertEqual(LuckgramAccountTokens.account(user: 0), "device_token")
        XCTAssertEqual(LuckgramAccountTokens.account(user: 777), "device_token.u777")
        XCTAssertNotEqual(LuckgramAccountTokens.account(user: 1), LuckgramAccountTokens.account(user: 2))
    }

    func testUserList() {
        XCTAssertEqual(LuckgramAccountTokens.decodeUsers(nil), [])
        XCTAssertEqual(LuckgramAccountTokens.decodeUsers("12, 34,12,x,0,"), [12, 34])
        XCTAssertEqual(LuckgramAccountTokens.encodeUsers([5, 0, 6, 5]), "5,6")
        XCTAssertEqual(LuckgramAccountTokens.decodeUsers(LuckgramAccountTokens.encodeUsers([9, 8])), [9, 8])
    }

    func testLegacyTokenOnlyForTheOnlyAccount() {
        XCTAssertTrue(LuckgramAccountTokens.adoptsLegacy(user: 5, loggedIn: [5]))
        // specs#209: two accounts, the old token may be linked to either one.
        XCTAssertFalse(LuckgramAccountTokens.adoptsLegacy(user: 5, loggedIn: [5, 6]))
        XCTAssertFalse(LuckgramAccountTokens.adoptsLegacy(user: 6, loggedIn: [5]))
        XCTAssertFalse(LuckgramAccountTokens.adoptsLegacy(user: 0, loggedIn: [0]))
        XCTAssertFalse(LuckgramAccountTokens.adoptsLegacy(user: 5, loggedIn: []))
    }
}
