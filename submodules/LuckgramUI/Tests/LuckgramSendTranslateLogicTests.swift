import XCTest
import LuckgramUI

/// specs#104: capsule labels and the list of chats with translate-before-sending on.
final class LuckgramSendTranslateLogicTests: XCTestCase {
    typealias L = LuckgramSendTranslateLogic

    func testCapsule() {
        XCTAssertEqual(L.capsule(from: "zh-Hans", to: "en"), "中 → EN")
        XCTAssertEqual(L.capsule(from: "en", to: "ja"), "EN → 日")
        XCTAssertEqual(L.capsule(from: "zh", to: "pt_BR"), "中 → PT")
        XCTAssertEqual(L.shortLabel("ko"), "한")
        XCTAssertEqual(L.shortLabel(nil), "?")
        XCTAssertEqual(L.shortLabel("und"), "?")
    }

    func testChats() {
        XCTAssertEqual(L.decodeChats(nil), [])
        XCTAssertEqual(L.decodeChats("1,2, 2,x,3"), [1, 2, 3])
        var stored = L.updatingChats(nil, peerId: 5, on: true)
        stored = L.updatingChats(stored, peerId: -100, on: true)
        XCTAssertEqual(L.decodeChats(stored), [5, -100])
        stored = L.updatingChats(stored, peerId: 5, on: false)
        XCTAssertEqual(stored, "-100")
        XCTAssertEqual(L.updatingChats(stored, peerId: -100, on: true), "-100")
    }
}
