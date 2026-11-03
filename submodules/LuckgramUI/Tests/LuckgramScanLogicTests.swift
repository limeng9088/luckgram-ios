import XCTest
import LuckgramUI

/// specs#92: scanned QR codes → Telegram's flows (same cases as Android ScanLogicTest).
final class LuckgramScanLogicTests: XCTestCase {
    typealias L = LuckgramScanLogic

    func testLogin() {
        XCTAssertEqual(L.kind("tg://login?token=AQIDBA"), .login)
        XCTAssertEqual(L.loginToken("tg://login?token=AQIDBA"), Data([1, 2, 3, 4]))
        XCTAssertEqual(L.loginToken("tg://login?token=-_8"), Data([0xfb, 0xff]))
        XCTAssertNil(L.loginToken("tg://login?token="))
        XCTAssertNil(L.loginToken("https://t.me/x"))
    }

    func testProxies() {
        XCTAssertEqual(L.kind("tg://proxy?server=1.2.3.4&port=443&secret=ee00"), .proxy)
        XCTAssertEqual(L.kind("tg://socks?server=1.2.3.4&port=1080"), .proxy)
        XCTAssertEqual(L.kind("https://t.me/proxy?server=1.2.3.4&port=443&secret=dd00"), .proxy)
        XCTAssertEqual(L.kind("t.me/socks?server=h&port=1"), .proxy)
        XCTAssertEqual(L.kind("HTTPS://TELEGRAM.ME/proxy?server=h&port=1&secret=x"), .proxy)
    }

    func testTelegramLinks() {
        XCTAssertEqual(L.kind("https://t.me/luckgram"), .telegram)
        XCTAssertEqual(L.kind("t.me/+8613800000000"), .telegram)
        XCTAssertEqual(L.kind("https://t.me/+AbCdEf"), .telegram)
        XCTAssertEqual(L.kind("tg://resolve?domain=luckgram"), .telegram)
        XCTAssertEqual(L.kind("tg://user?id=123"), .telegram)
        XCTAssertEqual(L.kind("https://www.t.me/luckgram"), .telegram)
        XCTAssertEqual(L.kind("https://t.me/proxybot"), .telegram)
    }

    func testWebAndText() {
        XCTAssertEqual(L.kind("https://example.com/a?b=1"), .web)
        XCTAssertEqual(L.kind("http://t.me.example.com/x"), .web)
        XCTAssertEqual(L.kind("https://t.me"), .web)
        XCTAssertEqual(L.kind("hello world"), .text)
        XCTAssertEqual(L.kind("WIFI:S:home;T:WPA;P:secret;;"), .text)
        XCTAssertEqual(L.kind(""), .text)
        XCTAssertEqual(L.kind(nil), .text)
    }

    func testUrls() {
        XCTAssertEqual(L.url("t.me/luckgram"), "https://t.me/luckgram")
        XCTAssertEqual(L.url(" https://t.me/luckgram "), "https://t.me/luckgram")
        XCTAssertEqual(L.url("tg://resolve?domain=x"), "tg://resolve?domain=x")
    }

    func testProxyStates() {
        XCTAssertEqual(L.proxyState(enabled: false, connected: true), .off)
        XCTAssertEqual(L.proxyState(enabled: true, connected: false), .connecting)
        XCTAssertEqual(L.proxyState(enabled: true, connected: true), .connected)
        XCTAssertEqual(L.Texts(zh: true).proxyState(.connecting), "连接中")
    }
}
