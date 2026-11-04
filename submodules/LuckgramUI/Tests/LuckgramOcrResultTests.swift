import XCTest
import LuckgramUI

/// specs#106 / #108: OCR result model shared by recognition and image translation.
final class LuckgramOcrResultTests: XCTestCase {
    private func line(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LuckgramOcrResult.Line {
        return LuckgramOcrResult.Line(text: text, box: LuckgramOcrResult.Box(x: x, y: y, width: w, height: h))
    }

    func testBoxesAreNormalizedTopLeft() {
        let b = LuckgramOcrResult.Box.fromPixels(left: 100, top: 50, right: 300, bottom: 150, w: 1000, h: 500)
        XCTAssertEqual(b.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(b.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(b.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(b.height, 0.2, accuracy: 1e-9)
        let v = LuckgramOcrResult.Box.fromBottomLeft(x: 0.1, y: 0.0, width: 0.5, height: 0.2)
        XCTAssertEqual(v.y, 0.8, accuracy: 1e-9)
        let c = LuckgramOcrResult.Box.fromPixels(left: -10, top: -10, right: 2000, bottom: 600, w: 1000, h: 500)
        XCTAssertEqual(c.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(c.width, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.height, 1.0, accuracy: 1e-9)
    }

    func testBlockJoinsLinesAndUnionsBoxes() {
        let b = LuckgramOcrResult.Block.of(lines: [line("第一行", 0.1, 0.1, 0.3, 0.05), line("second line", 0.1, 0.16, 0.5, 0.05)], language: "zh")
        XCTAssertEqual(b.text, "第一行\nsecond line")
        XCTAssertEqual(b.box.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(b.box.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(b.box.height, 0.11, accuracy: 1e-9)
        XCTAssertEqual(b.language, "zh")
        XCTAssertNil(LuckgramOcrResult.Block.of(lines: [], language: "und").language)
    }

    func testReadingOrderTopToBottomLeftToRight() {
        let right = LuckgramOcrResult.Block.of(lines: [line("B", 0.6, 0.1, 0.2, 0.1)], language: nil)
        let left = LuckgramOcrResult.Block.of(lines: [line("A", 0.1, 0.12, 0.2, 0.1)], language: nil)
        let below = LuckgramOcrResult.Block.of(lines: [line("C", 0.1, 0.5, 0.2, 0.1)], language: nil)
        XCTAssertEqual(LuckgramOcrResult.readingOrder([below, right, left]).map { $0.text }, ["A", "B", "C"])
    }

    func testTextLanguageAndTap() {
        let ja = LuckgramOcrResult.Block(text: "メニュー\nラーメン", language: "ja", box: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.2), lines: [])
        let en = LuckgramOcrResult.Block(text: "Menu", language: "en", box: .init(x: 0.1, y: 0.6, width: 0.2, height: 0.1), lines: [])
        let r = LuckgramOcrResult(imageWidth: 800, imageHeight: 600, language: LuckgramOcrResult.mainLanguage([ja, en]), source: .device, blocks: [ja, en])
        XCTAssertEqual(r.text, "メニュー\nラーメン\nMenu")
        XCTAssertEqual(r.language, "ja")
        XCTAssertTrue(r.hasText)
        XCTAssertEqual(r.block(atX: 0.2, y: 0.65)?.text, "Menu")
        XCTAssertNil(r.block(atX: 0.9, y: 0.9))
        XCTAssertFalse(LuckgramOcrResult(imageWidth: 1, imageHeight: 1, language: nil, source: .ai, blocks: []).hasText)
    }

    func testParagraphsAndScript() {
        let a = line("第一段第一行", 0.1, 0.10, 0.5, 0.04)
        let b = line("第一段第二行", 0.1, 0.15, 0.5, 0.04)
        let c = line("Second paragraph", 0.1, 0.40, 0.5, 0.04)
        let p = LuckgramOcrResult.paragraphs([c, b, a])
        XCTAssertEqual(p.map { $0.map { $0.text } }, [["第一段第一行", "第一段第二行"], ["Second paragraph"]])
        XCTAssertEqual(LuckgramOcrResult.scriptLanguage("今天下午三点开会"), "zh")
        XCTAssertEqual(LuckgramOcrResult.scriptLanguage("ラーメン 800円"), "ja")
        XCTAssertEqual(LuckgramOcrResult.scriptLanguage("안녕하세요"), "ko")
        XCTAssertNil(LuckgramOcrResult.scriptLanguage("Hello world"))
        XCTAssertEqual(LuckgramOcrResult.scriptLanguage("会议 Meeting 3pm 下午"), "zh")
    }

    func testAIFallback() {
        XCTAssertTrue(LuckgramOcrResult.offerAI(configOn: true, deviceFoundText: false))
        XCTAssertFalse(LuckgramOcrResult.offerAI(configOn: true, deviceFoundText: true))
        XCTAssertFalse(LuckgramOcrResult.offerAI(configOn: false, deviceFoundText: false))
        XCTAssertEqual(LuckgramOcrResult.aiBody(base64Jpeg: "abc", langHint: "ja")["lang_hint"] as? String, "ja")
        XCTAssertNil(LuckgramOcrResult.aiBody(base64Jpeg: "abc", langHint: nil)["lang_hint"])
        let json: [String: Any] = ["language": "th", "blocks": [
            ["text": "สวัสดี\r\nครับ", "language": "th", "box": ["x": 0.1, "y": 0.2, "width": 0.5, "height": 0.1]],
            ["text": "  "],
            ["text": "x", "box": ["x": 0.9, "y": -1, "width": 0.5, "height": 2]]
        ]]
        let r = LuckgramOcrResult.parseAI(json, imageWidth: 800, imageHeight: 600)
        XCTAssertEqual(r.source, .ai)
        XCTAssertEqual(r.language, "th")
        XCTAssertEqual(r.blocks.count, 2)
        XCTAssertEqual(r.blocks[0].text, "สวัสดี\nครับ")
        XCTAssertEqual(r.blocks[0].lines.count, 2)
        XCTAssertEqual(r.blocks[1].box.width, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.blocks[1].box.height, 1.0, accuracy: 1e-9)
        XCTAssertNil(r.blocks[1].language)
        XCTAssertEqual(r.text, "สวัสดี\nครับ\nx")
        XCTAssertTrue(LuckgramOcrResult.parseAI(nil, imageWidth: 1, imageHeight: 1).blocks.isEmpty)
    }
}
