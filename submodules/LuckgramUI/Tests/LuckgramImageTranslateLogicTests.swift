import XCTest
@testable import LuckgramUI

final class LuckgramImageTranslateLogicTests: XCTestCase {
    typealias L = LuckgramImageTranslateLogic

    func testTargetLanguageOrder() {
        XCTAssertEqual(L.targetLanguage(perChat: "en", imageDefault: "fr", readingTarget: "zh", appLanguage: "de"), "en")
        XCTAssertEqual(L.targetLanguage(perChat: "", imageDefault: "fr", readingTarget: "zh", appLanguage: "de"), "fr")
        XCTAssertEqual(L.targetLanguage(perChat: nil, imageDefault: " ", readingTarget: "zh", appLanguage: "de"), "zh")
        XCTAssertEqual(L.targetLanguage(perChat: nil, imageDefault: nil, readingTarget: nil, appLanguage: "de"), "de")
        XCTAssertEqual(L.targetLanguage(perChat: nil, imageDefault: nil, readingTarget: nil, appLanguage: nil), "en")
    }

    func testHeader() {
        XCTAssertEqual(L.header(fromName: "日本語", toName: "中文"), "日本語 → 中文 ▾")
        XCTAssertEqual(L.header(fromName: nil, toName: "English"), "→ English ▾")
    }

    func testShouldTranslate() {
        XCTAssertTrue(L.shouldTranslate(text: "ラーメン", blockLanguage: "ja", imageLanguage: nil, targetLanguage: "zh"))
        XCTAssertFalse(L.shouldTranslate(text: "拉面", blockLanguage: "zh-Hans", imageLanguage: nil, targetLanguage: "zh"))
        XCTAssertFalse(L.shouldTranslate(text: "¥ 1,200", blockLanguage: nil, imageLanguage: "ja", targetLanguage: "zh"))
        XCTAssertFalse(L.shouldTranslate(text: "Menu", blockLanguage: nil, imageLanguage: "en-US", targetLanguage: "en"))
        XCTAssertTrue(L.shouldTranslate(text: "Menu", blockLanguage: nil, imageLanguage: nil, targetLanguage: "zh"))
    }

    func testBatches() {
        let b = L.batches(Array(repeating: "abc", count: 45))
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b[0].count, 20)
        XCTAssertEqual(b[2][0], 40)
        let big = String(repeating: "x", count: 2000)
        let c = L.batches([big, big, "a"])
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[1], [1, 2])
    }

    /// Fake layout: characters per line = width / (0.6 × size), line height = 1.2 × size.
    private let fake: (String, Double, Double) -> Double = { text, size, width in
        let perLine = max(1, Int(width / (0.6 * size)))
        let lines = (text.count + perLine - 1) / perLine
        return Double(lines) * 1.2 * size
    }

    func testFitFontSize() {
        XCTAssertEqual(L.fitFontSize(text: "ab", width: 400, height: 50, lineHeight: 40, measure: fake), 36, accuracy: 0.01)
        let text = "a long translated sentence that wraps"
        let s = L.fitFontSize(text: text, width: 200, height: 50, lineHeight: 40, measure: fake)
        XCTAssertTrue(s < 36 && s >= L.minFontPx)
        XCTAssertLessThanOrEqual(fake(text, s, 200), 50)
        XCTAssertEqual(L.fitFontSize(text: String(repeating: "x", count: 500), width: 50, height: 10, lineHeight: 10, measure: fake), L.minFontPx, accuracy: 0.01)
    }

    func testRects() {
        XCTAssertEqual(L.pixelRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5, imageWidth: 100, imageHeight: 100).map { ($0 * 1000).rounded() / 1000 }, [10, 20, 60, 70])
        XCTAssertEqual(L.pixelRect(x: 0.9, y: -0.1, width: 0.5, height: 0.2, imageWidth: 100, imageHeight: 100).map { ($0 * 1000).rounded() / 1000 }, [90, 0, 100, 10])
        XCTAssertEqual(L.coverRect([0, 20, 60, 70], lineHeight: 10, imageWidth: 100, imageHeight: 100).map { ($0 * 1000).rounded() / 1000 }, [0, 18.8, 61.2, 71.2])
    }

    func testColors() {
        XCTAssertTrue(L.darkText(r: 255, g: 255, b: 255))
        XCTAssertFalse(L.darkText(r: 0, g: 0, b: 0))
        XCTAssertFalse(L.darkText(r: 30, g: 60, b: 120))
        XCTAssertTrue(L.darkText(r: 250, g: 220, b: 120))
    }

    func testHitTest() {
        let boxes: [[Double]] = [[0, 0, 1, 1], [0.2, 0.2, 0.2, 0.1]]
        XCTAssertEqual(L.hitTest(boxes: boxes, x: 0.3, y: 0.25), 1)
        XCTAssertEqual(L.hitTest(boxes: boxes, x: 0.8, y: 0.8), 0)
        XCTAssertNil(L.hitTest(boxes: [boxes[1]], x: 0.8, y: 0.8))
    }

    func testCopyText() {
        XCTAssertEqual(L.copyText(originals: ["ラーメン", "¥ 1,200", "餃子"], translations: ["Ramen", nil, "Gyoza"]), "Ramen\n¥ 1,200\nGyoza")
    }
}
