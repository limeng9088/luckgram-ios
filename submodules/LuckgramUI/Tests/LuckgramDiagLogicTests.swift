import XCTest
import LuckgramUI

final class LuckgramDiagLogicTests: XCTestCase {
    private let api = "api.luckgram.cc"

    // MARK: - Proxy choice

    func testProxyOffIsDirect() {
        XCTAssertEqual(LuckgramProxyRoute.decide(enabled: false, type: "SOCKS5", host: "1.2.3.4", port: 1080), LuckgramProxyRoute.direct)
        XCTAssertEqual(LuckgramProxyRoute.decide(enabled: true, type: nil, host: nil, port: 0), LuckgramProxyRoute.direct)
    }

    func testSocks5GoesThroughProxy() {
        XCTAssertEqual(LuckgramProxyRoute.decide(enabled: true, type: "SOCKS5", host: "proxy.example", port: 1080), LuckgramProxyRoute.socks5)
    }

    func testInvalidSocks5IsDirect() {
        XCTAssertEqual(LuckgramProxyRoute.decide(enabled: true, type: "SOCKS5", host: " ", port: 1080), LuckgramProxyRoute.direct)
        XCTAssertEqual(LuckgramProxyRoute.decide(enabled: true, type: "SOCKS5", host: "h", port: 0), LuckgramProxyRoute.direct)
        XCTAssertEqual(LuckgramProxyRoute.decide(enabled: true, type: "SOCKS5", host: "h", port: 70000), LuckgramProxyRoute.direct)
    }

    func testMtprotoAndWebGoDirectAndSaySo() {
        XCTAssertEqual(LuckgramProxyRoute.decide(enabled: true, type: "MTPROTO", host: "h", port: 443), LuckgramProxyRoute.mtprotoDirect)
        XCTAssertEqual(LuckgramProxyRoute.decide(enabled: true, type: "WEB", host: "h", port: 0), LuckgramProxyRoute.webDirect)
    }

    // MARK: - Redaction

    func testRouteDropsQueryAndApiHost() {
        XCTAssertEqual(LuckgramDiagLog.route("https://api.luckgram.cc/v1/ai/chat?x=1#f", apiHost: api), "/v1/ai/chat")
        XCTAssertEqual(LuckgramDiagLog.route("/v1/config?token=secret", apiHost: api), "/v1/config")
    }

    func testRouteKeepsOnlyHostAndPathOfOtherUrls() {
        let r = LuckgramDiagLog.route("https://media.luckgram.cc/square/p/ab/1.jpg?X-Amz-Signature=deadbeef&X-Amz-Credential=AKIA", apiHost: api)
        XCTAssertEqual(r, "media.luckgram.cc/square/p/ab/1.jpg")
        XCTAssertFalse(r.contains("Signature"))
        XCTAssertEqual(LuckgramDiagLog.route("https://user:pass@host.example", apiHost: api), "host.example/")
    }

    func testFormatHasOnlyMetadata() {
        var e = LuckgramDiagLog.Entry()
        e.timeMs = 1761955200000 // 2025-11-01T00:00:00Z
        e.feature = "summary"
        e.method = "POST"
        e.target = "https://api.luckgram.cc/v1/ai/chat?prompt=hello world"
        e.status = 502
        e.durationMs = 1234
        e.proxy = LuckgramProxyRoute.socks5
        e.requestId = "req-9f3a\nInjected: line"
        let line = LuckgramDiagLog.format(e, apiHost: api)
        XCTAssertEqual(line, "1761955200000 2025-11-01T00:00:00.000Z feature=summary route=POST /v1/ai/chat status=502 ms=1234 proxy=socks5 rid=req-9f3a_Injected:_line")
        XCTAssertFalse(line.contains("hello"))
        XCTAssertFalse(line.contains("\n"))
    }

    func testFormatFailureAndTelegramError() {
        var e = LuckgramDiagLog.Entry()
        e.timeMs = 1761955200000
        e.feature = "summary"
        e.target = "messages.getReplies"
        e.tgCode = 420
        e.tgError = "FLOOD_WAIT_30"
        XCTAssertTrue(LuckgramDiagLog.format(e, apiHost: api).hasSuffix("feature=summary route=messages.getReplies tg=420:FLOOD_WAIT_30"))
        e.tgCode = 0
        e.tgError = nil
        e.failure = "NSURLErrorDomain-1001"
        e.proxy = LuckgramProxyRoute.mtprotoDirect
        XCTAssertTrue(LuckgramDiagLog.format(e, apiHost: api).hasSuffix("exception=NSURLErrorDomain-1001 proxy=mtproto-direct"))
    }

    // MARK: - Retention

    func testTrimDropsOldLinesAndKeepsNewestWithinSize() {
        let now: Int64 = 10 * 24 * 60 * 60 * 1000
        let maxAgeMs = Int64(LuckgramDiagLog.maxAge * 1000)
        let lines = ["\(now - maxAgeMs - 1) old", "garbage", "\(now - 3000) a", "\(now - 2000) b", "\(now - 1000) c"]
        XCTAssertEqual(LuckgramDiagLog.trim(lines, nowMs: now, maxAge: LuckgramDiagLog.maxAge, maxBytes: 1000), ["\(now - 3000) a", "\(now - 2000) b", "\(now - 1000) c"])
        let oneLine = "\(now - 1000) c".utf8.count + 1
        XCTAssertEqual(LuckgramDiagLog.trim(lines, nowMs: now, maxAge: LuckgramDiagLog.maxAge, maxBytes: oneLine * 2), ["\(now - 2000) b", "\(now - 1000) c"])
    }

    // MARK: - Telegram errors

    func testTelegramErrorKinds() {
        XCTAssertEqual(LuckgramTelegramErrorKind.of(code: 420, text: "FLOOD_WAIT_30"), .floodWait)
        XCTAssertEqual(LuckgramTelegramErrorKind.floodWaitSeconds("FLOOD_WAIT_30"), 30)
        XCTAssertEqual(LuckgramTelegramErrorKind.of(code: 400, text: "CHANNEL_PRIVATE"), .privateChat)
        XCTAssertEqual(LuckgramTelegramErrorKind.of(code: 400, text: "CHAT_ADMIN_REQUIRED"), .noPermission)
        XCTAssertEqual(LuckgramTelegramErrorKind.of(code: 403, text: "SOMETHING_NEW"), .noPermission)
        XCTAssertEqual(LuckgramTelegramErrorKind.of(code: 400, text: "MSG_ID_INVALID"), .notFound)
        XCTAssertEqual(LuckgramTelegramErrorKind.of(code: 400, text: "SOMETHING_NEW"), .other)
        XCTAssertEqual(LuckgramTelegramErrorKind.of(code: -1000, text: "Timeout"), .network)
        XCTAssertEqual(LuckgramTelegramErrorKind.of(code: 0, text: nil), .network)
        XCTAssertEqual(LuckgramTelegramErrorKind.floodWaitSeconds("CHANNEL_PRIVATE"), 0)
    }
}
