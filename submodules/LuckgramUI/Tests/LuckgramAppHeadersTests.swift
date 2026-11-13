import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LuckgramUI

final class LuckgramAppHeadersTests: XCTestCase {
    func testBothHeaders() {
        let headers = LuckgramAppHeaders.headers(info: ["CFBundleShortVersionString": "13.1.1", "CFBundleVersion": "36413"])
        XCTAssertEqual(headers, ["X-Luckgram-App-Version": "13.1.1", "X-Luckgram-App-Build": "36413"])
    }

    func testMalformedValuesAreLeftOut() {
        XCTAssertEqual(LuckgramAppHeaders.headers(info: [:]), [:])
        XCTAssertEqual(LuckgramAppHeaders.headers(info: ["CFBundleShortVersionString": "13.1-beta", "CFBundleVersion": "36413a"]), [:])
        XCTAssertEqual(LuckgramAppHeaders.headers(info: ["CFBundleShortVersionString": "1.2.3.4.5", "CFBundleVersion": ""]), [:])
        XCTAssertEqual(LuckgramAppHeaders.headers(info: ["CFBundleVersion": 36413]), [:])
    }

    func testBuildOnly() {
        XCTAssertEqual(LuckgramAppHeaders.headers(info: ["CFBundleVersion": " 36413 "]), ["X-Luckgram-App-Build": "36413"])
    }

    func testApplyKeepsExisting() {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/config")!)
        request.setValue("1.0", forHTTPHeaderField: "X-Luckgram-App-Version")
        LuckgramAppHeaders.apply(["X-Luckgram-App-Version": "13.1.1", "X-Luckgram-App-Build": "36413"], to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Luckgram-App-Version"), "1.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Luckgram-App-Build"), "36413")
    }
}
