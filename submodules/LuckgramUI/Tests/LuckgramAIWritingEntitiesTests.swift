import XCTest
import Foundation
import LuckgramUI

/// Spec 21 review P2: formatting survives an AI rewrite where its text survived. Same cases as
/// Android `AiWritingEntitiesTest`.
final class LuckgramAIWritingEntitiesTests: XCTestCase {
    typealias E = LuckgramAIWritingEntities

    private func range(_ s: String, _ of: String, last: Bool = false) -> NSRange {
        return (s as NSString).range(of: of, options: last ? [.literal, .backwards] : [.literal])
    }

    func testMentionKeptWhenNameUnchanged() {
        let original = "tell Anna we are late"
        let result = "Please tell Anna that we're running late."
        XCTAssertEqual(E.relocate(original: original, ranges: [NSRange(location: 5, length: 4)], result: result), [12])
    }

    func testRangeDroppedWhenTextChanged() {
        let original = "this is VERY important"
        let result = "This is extremely important."
        XCTAssertEqual(E.relocate(original: original, ranges: [NSRange(location: 8, length: 4)], result: result), [nil])
    }

    func testRepeatedEmojiLandOnDifferentOccurrences() {
        let original = "ok 😀 and 😀"
        let result = "Okay 😀, and 😀!"
        let got = E.relocate(original: original, ranges: [range(original, "😀"), range(original, "😀", last: true)], result: result)
        XCTAssertEqual(got, [range(result, "😀").location, range(result, "😀", last: true).location])
    }

    func testNestedRangesBothFound() {
        let original = "see you, Anna Lee"
        let ranges = [NSRange(location: 4, length: 13), NSRange(location: 9, length: 8)]
        XCTAssertEqual(E.relocate(original: original, ranges: ranges, result: "See you, Anna Lee!"), [4, 9])
    }

    func testReorderedTextStillFindsRange() {
        let original = "link: https://t.me/x , thanks Bob"
        let ranges = [NSRange(location: 6, length: 14), NSRange(location: 30, length: 3)]
        let result = "Thanks, Bob! Here is the link: https://t.me/x"
        XCTAssertEqual(E.relocate(original: original, ranges: ranges, result: result), [range(result, "https").location, range(result, "Bob").location])
    }

    func testBlankAndInvalidRangesIgnored() {
        XCTAssertEqual(E.relocate(original: "a  b", ranges: [NSRange(location: 1, length: 2), NSRange(location: 2, length: 7)], result: "a  b"), [nil, nil])
    }
}
