import XCTest
@testable import TelegramCore

/// specs#82：错误 → 兜底的分支、语言参数、失败提示。
final class LuckgramTranslateFallbackLogicTests: XCTestCase {
    typealias L = LuckgramTranslateFallbackLogic

    func testFallsBackOnlyWhenTelegramGaveNoText() {
        XCTAssertTrue(L.shouldFallback(telegramGaveText: false))
        XCTAssertFalse(L.shouldFallback(telegramGaveText: true))
    }

    func testLogsTelegramErrorTimeoutOrEmpty() {
        XCTAssertEqual(L.telegramFailure(errorText: "TRANSLATIONS_DISABLED_ALT", timedOut: false), "TRANSLATIONS_DISABLED_ALT")
        XCTAssertEqual(L.telegramFailure(errorText: " FLOOD_WAIT_12 ", timedOut: false), "FLOOD_WAIT_12")
        XCTAssertEqual(L.telegramFailure(errorText: nil, timedOut: true), L.timeout)
        XCTAssertEqual(L.telegramFailure(errorText: "X", timedOut: true), L.timeout)
        XCTAssertEqual(L.telegramFailure(errorText: nil, timedOut: false), L.emptyResult)
        XCTAssertEqual(L.telegramFailure(errorText: "", timedOut: false), L.emptyResult)
    }

    func testAiLanguageIsIso639() {
        XCTAssertEqual(L.aiLanguage("en"), "en")
        XCTAssertEqual(L.aiLanguage("en_US"), "en")
        XCTAssertEqual(L.aiLanguage("DE-de"), "de")
        XCTAssertEqual(L.aiLanguage("zh"), "zh")
        XCTAssertEqual(L.aiLanguage("zh_CN"), "zh")
        XCTAssertEqual(L.aiLanguage("zh-hans"), "zh")
        XCTAssertEqual(L.aiLanguage("zh_TW"), "zh-Hant")
        XCTAssertEqual(L.aiLanguage("zh-Hant"), "zh-Hant")
        XCTAssertEqual(L.aiLanguage("zh-HK"), "zh-Hant")
        XCTAssertEqual(L.aiLanguage("pt_br"), "pt-BR")
        XCTAssertEqual(L.aiLanguage("pt-PT"), "pt")
        XCTAssertEqual(L.aiLanguage("nb"), "no")
        XCTAssertEqual(L.aiLanguage("iw"), "he")
        XCTAssertEqual(L.aiLanguage("in"), "id")
        XCTAssertEqual(L.aiLanguage("fil"), "fil")
        XCTAssertNil(L.aiLanguage(nil))
        XCTAssertNil(L.aiLanguage(""))
        XCTAssertNil(L.aiLanguage("und"))
        XCTAssertNil(L.aiLanguage("x"))
        XCTAssertNil(L.aiLanguage("english"))
        XCTAssertNil(L.aiLanguage("e1"))
    }

    func testFailureFromServerCode() {
        XCTAssertEqual(L.failure(code: "network_error"), .network)
        XCTAssertEqual(L.failure(code: "quota_exceeded"), .quota)
        XCTAssertEqual(L.failure(code: "input_too_large"), .tooLong)
        XCTAssertEqual(L.failure(code: "consent_denied"), .consent)
        XCTAssertEqual(L.failure(code: "upstream_unavailable"), .other)
        XCTAssertEqual(L.failure(code: nil), .other)
    }

    func testFailureMessagesSayWhy() {
        XCTAssertEqual(L.failureMessage(.network, chinese: true), "网络不通，请检查网络或代理")
        XCTAssertEqual(L.failureMessage(.quota, chinese: true), "今日翻译次数已用完，明天再来")
        XCTAssertEqual(L.failureMessage(.tooLong, chinese: true), "这段文字太长，无法翻译")
        XCTAssertEqual(L.failureMessage(.other, chinese: true), "翻译失败，请稍后再试")
        // declining AI consent means "Telegram only": generic message
        XCTAssertEqual(L.failureMessage(.consent, chinese: true), L.failureMessage(.other, chinese: true))
        XCTAssertNotEqual(L.failureMessage(.network, chinese: false), L.failureMessage(.other, chinese: false))
    }
}
