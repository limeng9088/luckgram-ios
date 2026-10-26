import XCTest
@testable import ChatListUI

/// Luckgram keyword folders — matching rules from specs/06-keyword-folders.md:
/// case-insensitive, CJK keywords match as substrings, other keywords as whole words.
/// Same cases as Android's KeywordMatcherTest.
final class KeywordFolderMatcherTests: XCTestCase {
    private let invoice = ["发票", "invoice"]

    private func matches(_ text: String, _ keyword: String) -> Bool {
        return !keywordFolderRanges(in: text, keywords: [keyword]).isEmpty
    }

    func testChineseMatchesAsSubstring() {
        XCTAssertTrue(self.matches("请把电子发票发我", "发票"))
        XCTAssertTrue(self.matches("发票", "发票"))
        XCTAssertTrue(self.matches("增值税发票号码", "发票"))
    }

    func testEnglishMatchesWholeWordsOnly() {
        XCTAssertTrue(self.matches("Invoice #12 attached", "invoice"))
        XCTAssertTrue(self.matches("see the invoice.", "invoice"))
        XCTAssertTrue(self.matches("(invoice)", "invoice"))
        XCTAssertFalse(self.matches("two invoices", "invoice"))
        XCTAssertFalse(self.matches("reinvoice", "invoice"))
        XCTAssertFalse(self.matches("invoice_id", "invoice"))
    }

    func testEnglishNextToChineseIsAWordBoundary() {
        XCTAssertTrue(self.matches("这是invoice号", "invoice"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(self.matches("INVOICE", "invoice"))
        XCTAssertTrue(self.matches("invoice", "INVOICE"))
    }

    func testRangesSkipRejectedHits() {
        let ranges = keywordFolderRanges(in: "invoices, invoice", keywords: ["invoice"])
        XCTAssertEqual(ranges.map { $0.0 }, [NSRange(location: 10, length: 7)])
    }

    func testRangesCoverEveryHit() {
        let ranges = keywordFolderRanges(in: "发票：invoice 与 发票", keywords: self.invoice)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(Set(ranges.map { $0.1 }), Set(self.invoice))
    }

    func testFirstMatchUsesFolderOrder() {
        XCTAssertEqual(keywordFolderFirstMatch(text: "invoice 和 发票", keywords: self.invoice), "发票")
        XCTAssertEqual(keywordFolderFirstMatch(text: "Invoice only", keywords: self.invoice), "invoice")
        XCTAssertNil(keywordFolderFirstMatch(text: "nothing here", keywords: self.invoice))
        XCTAssertNil(keywordFolderFirstMatch(text: "", keywords: self.invoice))
    }

    func testEmptyKeywordNeverMatches() {
        XCTAssertFalse(self.matches("anything", ""))
    }

    func testLocalFolderIdsNeverCollideWithCloudIds() {
        XCTAssertFalse(isKeywordFolderFilterId(255))
        XCTAssertFalse(isKeywordFolderFilterId(nil))
        XCTAssertTrue(isKeywordFolderFilterId(keywordFolderFilterIdBase + 1))
    }
}
