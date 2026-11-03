import XCTest
@testable import LuckgramUI

final class LuckgramAccountLimitTests: XCTestCase {
    func testDefaults() {
        XCTAssertEqual(LuckgramAccountLimit.limit(isPro: false, remoteMaxFree: 20, remoteMaxPro: 50), 20)
        XCTAssertEqual(LuckgramAccountLimit.limit(isPro: true, remoteMaxFree: 20, remoteMaxPro: 50), 50)
    }

    func testFreeNeverBelowTwentyNorAboveCapacity() {
        XCTAssertEqual(LuckgramAccountLimit.maxFree(5), 20)
        XCTAssertEqual(LuckgramAccountLimit.maxFree(30), 30)
        XCTAssertEqual(LuckgramAccountLimit.maxFree(500), 50)
    }

    func testProNeverBelowFree() {
        XCTAssertEqual(LuckgramAccountLimit.maxPro(remoteMaxFree: 20, remoteMaxPro: 22), 22)
        XCTAssertEqual(LuckgramAccountLimit.maxPro(remoteMaxFree: 30, remoteMaxPro: 22), 30)
        XCTAssertEqual(LuckgramAccountLimit.maxPro(remoteMaxFree: 20, remoteMaxPro: 999), 50)
    }

    func testExpiredProKeepsAccountsButCannotAdd() {
        let free = LuckgramAccountLimit.limit(isPro: false, remoteMaxFree: 20, remoteMaxPro: 50)
        XCTAssertFalse(LuckgramAccountLimit.canAdd(activated: 35, limit: free))
        XCTAssertFalse(LuckgramAccountLimit.canAdd(activated: 20, limit: free))
        XCTAssertTrue(LuckgramAccountLimit.canAdd(activated: 19, limit: free))
    }

    func testUpgradeOfferedOnlyWhenProRaisesTheLimit() {
        XCTAssertTrue(LuckgramAccountLimit.offerUpgrade(isPro: false, remoteMaxFree: 20, remoteMaxPro: 50))
        XCTAssertFalse(LuckgramAccountLimit.offerUpgrade(isPro: true, remoteMaxFree: 20, remoteMaxPro: 50))
        XCTAssertFalse(LuckgramAccountLimit.offerUpgrade(isPro: false, remoteMaxFree: 50, remoteMaxPro: 50))
    }
}
