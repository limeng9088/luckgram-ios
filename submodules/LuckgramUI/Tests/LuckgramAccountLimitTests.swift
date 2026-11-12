import XCTest
@testable import LuckgramUI

final class LuckgramAccountLimitTests: XCTestCase {
    func testDefaults() {
        XCTAssertEqual(LuckgramAccountLimit.defaultMaxFree, 10)
        XCTAssertEqual(LuckgramAccountLimit.limit(isPro: false, remoteMaxFree: LuckgramAccountLimit.defaultMaxFree), 10)
        XCTAssertEqual(LuckgramAccountLimit.limit(isPro: true, remoteMaxFree: LuckgramAccountLimit.defaultMaxFree), LuckgramAccountLimit.slotCapacity)
    }

    func testFreeFollowsRemoteWithinSlots() {
        XCTAssertEqual(LuckgramAccountLimit.maxFree(0), 1)
        XCTAssertEqual(LuckgramAccountLimit.maxFree(3), 3)
        XCTAssertEqual(LuckgramAccountLimit.maxFree(20), 20)
        XCTAssertEqual(LuckgramAccountLimit.maxFree(500), 50)
    }

    func testProOnlyBoundBySlots() {
        XCTAssertEqual(LuckgramAccountLimit.maxPro, LuckgramAccountLimit.slotCapacity)
        XCTAssertEqual(LuckgramAccountLimit.limit(isPro: true, remoteMaxFree: 3), LuckgramAccountLimit.slotCapacity)
    }

    func testFreeAboveLimitKeepsAccountsButCannotAdd() {
        let free = LuckgramAccountLimit.limit(isPro: false, remoteMaxFree: 5)
        XCTAssertFalse(LuckgramAccountLimit.canAdd(activated: 12, limit: free))
        XCTAssertFalse(LuckgramAccountLimit.canAdd(activated: 5, limit: free))
        XCTAssertTrue(LuckgramAccountLimit.canAdd(activated: 4, limit: free))
        let pro = LuckgramAccountLimit.limit(isPro: true, remoteMaxFree: 5)
        XCTAssertTrue(LuckgramAccountLimit.canAdd(activated: 12, limit: pro))
        XCTAssertFalse(LuckgramAccountLimit.canAdd(activated: LuckgramAccountLimit.slotCapacity, limit: pro))
    }

    func testUpgradeOfferedOnlyWhenProRaisesTheLimit() {
        XCTAssertTrue(LuckgramAccountLimit.offerUpgrade(isPro: false, remoteMaxFree: 5))
        XCTAssertFalse(LuckgramAccountLimit.offerUpgrade(isPro: true, remoteMaxFree: 5))
        XCTAssertFalse(LuckgramAccountLimit.offerUpgrade(isPro: false, remoteMaxFree: 50))
    }
}
