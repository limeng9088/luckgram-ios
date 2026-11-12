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

    func testOnlyNearZeroInputIsSilence() {
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilent(peakLevel: 0))
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilent(peakLevel: 0.119))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilent(peakLevel: 0.12))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilent(peakLevel: 0.6))
    }

    func testStockSilencePhrasesAreNotTranscripts() {
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination("Thank you so much for watching."))
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination(" ご視聴ありがとうございました "))
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination("私のビデオを見てくれてありがとう。"))
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination("メッセージなし。ご視聴ありがとうございました。"))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("Thank you so much for watching my long video about cooking, see you at 8"))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("晚上八点见"))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination(""))
    }

    func testLoopsAreNotTranscripts() {
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination("BREATHING IN DEEPLY BREATHING OUT DEEPLY BREATHING IN DEEPLY BREATHING OUT DEEPLY"))
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination("下方影片の説明については、下方のリンク先をクリックすることで、下方のリンク先をクリックすることができます。"))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("哈哈哈哈哈哈哈哈哈哈哈哈"))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("好的好的好的"))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("明天上午十点开会，记得带上周的报告，下午三点再和客户开会"))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("I will be there at eight, and I will bring the documents you asked for"))
    }

    func testAClickIsNotAVoice() {
        var loud = 0.0
        loud = LuckgramVoiceBarLogic.loudSeconds(loud, level: 0.9, sincePrevious: 2.0)
        XCTAssertEqual(loud, 0.25, accuracy: 0.0001)
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilent(peakLevel: 0.9, loudSeconds: loud))
        loud = LuckgramVoiceBarLogic.loudSeconds(loud, level: 0.05, sincePrevious: 0.05)
        XCTAssertEqual(loud, 0.25, accuracy: 0.0001)
        for _ in 0 ..< 4 {
            loud = LuckgramVoiceBarLogic.loudSeconds(loud, level: 0.4, sincePrevious: 0.05)
        }
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilent(peakLevel: 0.9, loudSeconds: loud))
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilent(peakLevel: 0.05, loudSeconds: 5.0))
    }

    func testRepeatedAndFillerSentencesAreNotTranscripts() {
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination("That's it. Thank you. God bless. God bless. God bless."))
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination("Thank you. Bye.", weakSignal: true))
        XCTAssertTrue(LuckgramVoiceBarLogic.isSilenceHallucination("谢谢。", weakSignal: true))
        // said out loud, these are real
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("Thank you. Bye."))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("谢谢"))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("Thank you, see you at eight.", weakSignal: true))
        XCTAssertFalse(LuckgramVoiceBarLogic.isSilenceHallucination("好的。好的。", weakSignal: true))
        XCTAssertTrue(LuckgramVoiceBarLogic.isWeak(peakLevel: 0.2))
        XCTAssertFalse(LuckgramVoiceBarLogic.isWeak(peakLevel: 0.35))
    }
}
