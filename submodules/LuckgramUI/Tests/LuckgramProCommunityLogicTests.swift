import XCTest
import LuckgramUI

/// specs#89 (31): S14 invite answers, links, channel ids, row visibility.
final class LuckgramProCommunityLogicTests: XCTestCase {
    typealias L = LuckgramProCommunityLogic

    func testInviteLinkIsJoin() {
        XCTAssertEqual(L.parse(["invite_link": "https://t.me/+AbC123", "expires_at": "2026-11-04T00:00:00Z"]), .join(link: "https://t.me/+AbC123"))
    }

    func testAlreadyMemberInBody() {
        XCTAssertEqual(L.parse(["already_member": true, "chat_id": NSNumber(value: Int64(-1001234567890))]), .alreadyMember(channelId: 1234567890, link: nil))
        XCTAssertEqual(L.parse(["status": "already_member", "chat_id": "-1001234567890", "chat_link": "https://t.me/c/1234567890"]),
                       .alreadyMember(channelId: 1234567890, link: "https://t.me/c/1234567890"))
    }

    func testAlreadyMemberAsError() {
        XCTAssertEqual(L.alreadyMember(nil), .alreadyMember(channelId: 0, link: nil))
    }

    func testBadAnswers() {
        XCTAssertEqual(L.parse(["invite_link": "https://evil.example/+x"]), .badAnswer)
        XCTAssertEqual(L.parse([:]), .badAnswer)
        XCTAssertEqual(L.parse(nil), .badAnswer)
    }

    func testLinks() {
        XCTAssertTrue(L.isOpenableLink("https://t.me/+x"))
        XCTAssertTrue(L.isOpenableLink("tg://join?invite=x"))
        XCTAssertFalse(L.isOpenableLink("https://t.me/"))
        XCTAssertFalse(L.isOpenableLink("http://t.me/+x"))
        XCTAssertFalse(L.isOpenableLink(nil))
    }

    func testChannelIds() {
        XCTAssertEqual(L.channelId(botApiId: -1001234567890), 1234567890)
        XCTAssertEqual(L.channelId(botApiId: 42), 42)
        XCTAssertEqual(L.channelId(botApiId: -42), 0)
        XCTAssertEqual(L.channelId(botApiId: 0), 0)
    }

    func testRow() {
        XCTAssertTrue(L.showRow(featureEnabled: true, hasPerk: true))
        XCTAssertFalse(L.showRow(featureEnabled: false, hasPerk: true))
        XCTAssertFalse(L.showRow(featureEnabled: true, hasPerk: false))
    }
}
