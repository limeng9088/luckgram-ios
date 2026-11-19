import XCTest
import LuckgramUI

/// specs#207: the pinned "Luckgram AI" row hides while the chat list is scrolled.
final class LuckgramAIRowScrollTests: XCTestCase {
    func testShownAtTheTop() {
        XCTAssertFalse(LuckgramAIRowScroll.hidden(wasHidden: false, offset: 0))
        XCTAssertFalse(LuckgramAIRowScroll.hidden(wasHidden: false, offset: -40)) // overscroll / pull down
        XCTAssertFalse(LuckgramAIRowScroll.hidden(wasHidden: false, offset: 24))
    }

    func testHiddenOnceScrolled() {
        XCTAssertTrue(LuckgramAIRowScroll.hidden(wasHidden: false, offset: 25))
        XCTAssertTrue(LuckgramAIRowScroll.hidden(wasHidden: false, offset: 2000))
    }

    func testStaysHiddenUntilBackAtTheTop() {
        XCTAssertTrue(LuckgramAIRowScroll.hidden(wasHidden: true, offset: 20))
        XCTAssertTrue(LuckgramAIRowScroll.hidden(wasHidden: true, offset: 5))
        XCTAssertFalse(LuckgramAIRowScroll.hidden(wasHidden: true, offset: 4))
        XCTAssertFalse(LuckgramAIRowScroll.hidden(wasHidden: true, offset: 0))
    }
}
