import XCTest
import LuckgramUI

/// specs#98: the post-login folder offer.
final class LuckgramFolderOfferLogicTests: XCTestCase {
    typealias L = LuckgramFolderOfferLogic

    func testSlugOnlyFromAddlistLinks() {
        XCTAssertEqual(L.slug("https://t.me/addlist/AbC_d-12xyz"), "AbC_d-12xyz")
        XCTAssertEqual(L.slug(" https://t.me/addlist/abcd "), "abcd")
        XCTAssertNil(L.slug(nil))
        XCTAssertNil(L.slug(""))
        XCTAssertNil(L.slug("t.me/addlist/abcd"))
        XCTAssertNil(L.slug("https://t.me/luckgram"))
        XCTAssertNil(L.slug("https://t.me/addlist/ab"))
        XCTAssertNil(L.slug("https://t.me/addlist/abcd?x=1"))
        XCTAssertNil(L.slug("https://evil.com/addlist/abcd"))
    }

    func testCheckedOnlyWhenOnWithLinkAndNotSeen() {
        let link = "https://t.me/addlist/abcd"
        XCTAssertTrue(L.shouldCheck(enabled: true, link: link, seen: false, userId: 42))
        XCTAssertFalse(L.shouldCheck(enabled: false, link: link, seen: false, userId: 42))
        XCTAssertFalse(L.shouldCheck(enabled: true, link: "", seen: false, userId: 42))
        XCTAssertFalse(L.shouldCheck(enabled: true, link: link, seen: true, userId: 42))
        XCTAssertFalse(L.shouldCheck(enabled: true, link: link, seen: false, userId: 0))
    }

    func testOfferedOnlyWhenNotAddedAndNotEmpty() {
        XCTAssertTrue(L.shouldOffer(alreadyAdded: false, peers: 3))
        XCTAssertFalse(L.shouldOffer(alreadyAdded: true, peers: 3))
        XCTAssertFalse(L.shouldOffer(alreadyAdded: false, peers: 0))
    }

    func testSeenKeyPerUser() {
        XCTAssertEqual(L.seenKey(userId: 42), "onboarding_folder_seen_42")
    }
}
