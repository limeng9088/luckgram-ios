import XCTest
import LuckgramUI

/// specs#145: zones of the 「按住 说话」 overlay.
final class LuckgramVoiceBarLogicTests: XCTestCase {
    func testReleasingInTheBottomAreaSends() {
        XCTAssertEqual(LuckgramVoiceBarLogic.zone(x: 10, y: 900, width: 400, actionLineY: 800), .send)
        XCTAssertEqual(LuckgramVoiceBarLogic.zone(x: 390, y: 800, width: 400, actionLineY: 800), .send)
    }

    func testAboveTheLineLeftCancelsRightConverts() {
        XCTAssertEqual(LuckgramVoiceBarLogic.zone(x: 199, y: 799, width: 400, actionLineY: 800), .cancel)
        XCTAssertEqual(LuckgramVoiceBarLogic.zone(x: 200, y: 799, width: 400, actionLineY: 800), .text)
        XCTAssertEqual(LuckgramVoiceBarLogic.zone(x: 399, y: 0, width: 400, actionLineY: 800), .text)
    }

    func testBeforeLayoutEverythingSends() {
        XCTAssertEqual(LuckgramVoiceBarLogic.zone(x: 0, y: 0, width: 0, actionLineY: 0), .send)
    }

    func testDurationIsMinutesAndSeconds() {
        XCTAssertEqual(LuckgramVoiceBarLogic.formatDuration(0), "0:00")
        XCTAssertEqual(LuckgramVoiceBarLogic.formatDuration(9.99), "0:09")
        XCTAssertEqual(LuckgramVoiceBarLogic.formatDuration(65), "1:05")
        XCTAssertEqual(LuckgramVoiceBarLogic.formatDuration(-5), "0:00")
    }
}
