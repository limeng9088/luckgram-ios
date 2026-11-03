import XCTest
@testable import LuckgramUI

final class LuckgramVersionLineTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(LuckgramVersionLine.format(version: "13.1.1", build: "36067", commit: "19e5f52a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e"), "Luckgram 13.1.1 (36067) \u{00B7} 19e5f52")
    }

    func testUnknownCommit() {
        XCTAssertEqual(LuckgramVersionLine.format(version: "13.1.1", build: "36067", commit: nil), "Luckgram 13.1.1 (36067) \u{00B7} unknown")
        XCTAssertEqual(LuckgramVersionLine.shortCommit(""), "unknown")
        XCTAssertEqual(LuckgramVersionLine.shortCommit("unknown"), "unknown")
        XCTAssertEqual(LuckgramVersionLine.shortCommit("abc"), "unknown")
        XCTAssertEqual(LuckgramVersionLine.shortCommit(" ABCDEF1234 "), "abcdef1")
    }

    func testMissingVersion() {
        XCTAssertEqual(LuckgramVersionLine.format(version: nil, build: " ", commit: "abcdef1"), "Luckgram unknown (unknown) \u{00B7} abcdef1")
    }
}
