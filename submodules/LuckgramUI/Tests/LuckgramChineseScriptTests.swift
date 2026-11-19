import XCTest
import LuckgramUI

/// luckgram-ios#145: ?script= for /v1/ai/transcribe follows the UI language.
final class LuckgramChineseScriptTests: XCTestCase {
    func testChineseCodes() {
        for code in ["zh", "zh-hans", "zh-hans-beta", "zh-Hans-CN", "zh_CN", "classic-zh-cn", "zhcncc"] {
            XCTAssertEqual(LuckgramChineseScript.of(code), "Hans", code)
        }
        for code in ["zh-hant", "zh-hant-beta", "zh-Hant-TW", "zh_TW", "zh-HK", "zh-mo", "taiwan"] {
            XCTAssertEqual(LuckgramChineseScript.of(code), "Hant", code)
        }
    }

    func testOtherLanguagesHaveNoScript() {
        for code in ["en", "ja", "ko", "en-US", "", "und"] {
            XCTAssertNil(LuckgramChineseScript.of(code), code)
        }
        XCTAssertNil(LuckgramChineseScript.of(nil))
    }

    func testUiLanguageFirstThenSystem() {
        XCTAssertEqual(LuckgramChineseScript.pick(appLanguageCode: "zh-hant-beta", systemLanguage: "zh-Hans-CN"), "Hant")
        XCTAssertEqual(LuckgramChineseScript.pick(appLanguageCode: "en", systemLanguage: "zh-Hant-HK"), "Hant")
        XCTAssertEqual(LuckgramChineseScript.pick(appLanguageCode: nil, systemLanguage: "zh-Hans"), "Hans")
        XCTAssertNil(LuckgramChineseScript.pick(appLanguageCode: "en", systemLanguage: "en-US"))
    }
}
