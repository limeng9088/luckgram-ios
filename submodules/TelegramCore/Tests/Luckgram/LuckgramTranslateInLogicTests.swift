import XCTest
@testable import TelegramCore

/// spec 01 A：一键翻译按钮、不翻译的语言、目标语言、标题、按消息保存。
final class LuckgramTranslateInLogicTests: XCTestCase {
    typealias L = LuckgramTranslateInLogic

    func testButtonForForeignIncomingTextOnly() {
        XCTAssertTrue(L.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: "en", doNotTranslate: ["zh"], toLang: "zh"))
        XCTAssertFalse(L.showButton(featureOn: false, outgoing: false, hasText: true, detectedLang: "en", doNotTranslate: ["zh"], toLang: "zh"))
        XCTAssertFalse(L.showButton(featureOn: true, outgoing: true, hasText: true, detectedLang: "en", doNotTranslate: ["zh"], toLang: "zh"))
        XCTAssertFalse(L.showButton(featureOn: true, outgoing: false, hasText: false, detectedLang: "en", doNotTranslate: ["zh"], toLang: "zh"))
        XCTAssertFalse(L.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: nil, doNotTranslate: ["zh"], toLang: "zh"))
    }

    func testDoNotTranslateLanguagesHideTheButton() {
        XCTAssertFalse(L.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: "zh-Hant", doNotTranslate: ["zh"], toLang: "zh"))
        XCTAssertFalse(L.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: "en", doNotTranslate: ["zh", "en"], toLang: "zh"))
        XCTAssertTrue(L.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: "es", doNotTranslate: ["zh", "en"], toLang: "zh"))
        XCTAssertFalse(L.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: "en", doNotTranslate: [], toLang: "en_US"))
        XCTAssertFalse(L.showButton(featureOn: true, outgoing: false, hasText: true, detectedLang: "nb", doNotTranslate: ["no"], toLang: "zh"))
    }

    func testBase() {
        XCTAssertEqual(L.base("en_US"), "en")
        XCTAssertEqual(L.base("zh-Hant"), "zh")
        XCTAssertEqual(L.base("nb"), "no")
        XCTAssertNil(L.base(" "))
        XCTAssertNil(L.base("und"))
        XCTAssertNil(L.base(nil))
    }

    func testTargetLanguage() {
        // specs#93: only the user's choice, never the app / system language
        XCTAssertEqual(L.targetLanguage(chosen: "es"), "es")
        XCTAssertEqual(L.targetLanguage(chosen: " ja "), "ja")
        XCTAssertNil(L.targetLanguage(chosen: ""))
        XCTAssertNil(L.targetLanguage(chosen: nil))
    }

    func testHeaderAndMenuLabels() {
        XCTAssertEqual(L.header(fromName: "英语", toName: "中文", chinese: true), "已翻译 · 英语 → 中文")
        XCTAssertEqual(L.header(fromName: nil, toName: "中文", chinese: true), "已翻译 · 中文")
        XCTAssertEqual(L.header(fromName: "English", toName: "Chinese", chinese: false), "Translated · English → Chinese")
        XCTAssertEqual(L.menuLabel(translated: false, chinese: true), "翻译")
        XCTAssertEqual(L.menuLabel(translated: true, chinese: true), "撤销翻译")
    }

    func testStateKey() {
        XCTAssertEqual(L.stateKey(account: 1, peerId: -100, messageId: 42, textKey: "abc", voice: false), "1:-100:42:abc")
        XCTAssertEqual(L.stateKey(account: 1, peerId: -100, messageId: 42, textKey: "abc", voice: true), "v1:-100:42:abc")
        XCTAssertNotEqual(L.stateKey(account: 1, peerId: -100, messageId: 42, textKey: "abc", voice: false), L.stateKey(account: 1, peerId: -100, messageId: 42, textKey: "abd", voice: false))
    }

    func testLanguagesRoundTrip() {
        let a = L.decodeLanguages(L.encodeLanguages(from: "en", to: "zh"))
        XCTAssertEqual(a.from, "en")
        XCTAssertEqual(a.to, "zh")
        let b = L.decodeLanguages(L.encodeLanguages(from: nil, to: "zh"))
        XCTAssertNil(b.from)
        XCTAssertEqual(b.to, "zh")
    }
}
