import XCTest
import LuckgramUI

/// specs#81: several API entries, switch only on network failures, remember, probe, rewrite.
final class LuckgramEndpointsTests: XCTestCase {
    private let a = "https://api.luckgram.cc"
    private let b = "https://backup.luckgram.cc"

    private func ep(_ remembered: String? = nil) -> LuckgramEndpoints {
        return LuckgramEndpoints(bases: [a, b], remembered: remembered)
    }

    func testParseKeepsOrderDropsJunk() {
        XCTAssertEqual(LuckgramEndpoints.parse([" https://api.luckgram.cc/ ", "http://insecure.luckgram.cc", "https://backup.luckgram.cc,https://api.luckgram.cc"]), [a, b])
        XCTAssertEqual(LuckgramEndpoints.parse([]), [])
        XCTAssertEqual(LuckgramEndpoints.parse(["https://"]), [])
    }

    func testStartsWithFirstAndTriesOthersInOrder() {
        let e = ep()
        XCTAssertEqual(e.current, a)
        XCTAssertEqual(e.attemptOrder(), [a, b])
        XCTAssertFalse(e.usingBackup)
    }

    func testRemembersWorkingEntry() {
        let e = ep()
        XCTAssertTrue(e.markWorking(b))
        XCTAssertEqual(e.current, b)
        XCTAssertEqual(e.attemptOrder(), [b, a])
        XCTAssertFalse(e.markWorking(b))
        XCTAssertFalse(e.markWorking("https://other.luckgram.cc"))
        XCTAssertEqual(ep(b + "/").current, b)
        XCTAssertEqual(ep("https://gone.luckgram.cc").current, a)
    }

    func testOnlyNetworkFailuresSwitch() {
        let d = "NSURLErrorDomain"
        XCTAssertTrue(LuckgramEndpoints.shouldSwitch(domain: d, code: -1003, hasBody: true, bodyBytesSent: 0)) // cannot find host
        XCTAssertTrue(LuckgramEndpoints.shouldSwitch(domain: d, code: -1004, hasBody: false, bodyBytesSent: 0)) // cannot connect
        XCTAssertTrue(LuckgramEndpoints.shouldSwitch(domain: d, code: -1200, hasBody: true, bodyBytesSent: 0)) // TLS failed
        XCTAssertTrue(LuckgramEndpoints.shouldSwitch(domain: d, code: -1005, hasBody: false, bodyBytesSent: 0)) // reset
        XCTAssertTrue(LuckgramEndpoints.shouldSwitch(domain: d, code: -1001, hasBody: true, bodyBytesSent: 0)) // timeout before sending
        // the body (partly) went out: the server may have it, don't send it twice
        XCTAssertFalse(LuckgramEndpoints.shouldSwitch(domain: d, code: -1001, hasBody: true, bodyBytesSent: 512))
        XCTAssertFalse(LuckgramEndpoints.shouldSwitch(domain: d, code: -1005, hasBody: true, bodyBytesSent: 1))
        // cancelled, offline, other domains
        XCTAssertFalse(LuckgramEndpoints.shouldSwitch(domain: d, code: -999, hasBody: false, bodyBytesSent: 0))
        XCTAssertFalse(LuckgramEndpoints.shouldSwitch(domain: d, code: -1009, hasBody: false, bodyBytesSent: 0))
        XCTAssertFalse(LuckgramEndpoints.shouldSwitch(domain: "LuckgramAI", code: -1003, hasBody: false, bodyBytesSent: 0))
    }

    func testProbesFirstEntryOnlyWhileOnBackup() {
        let e = ep()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(e.takeProbe(now: t0))
        e.markWorking(b)
        XCTAssertTrue(e.takeProbe(now: t0)) // cold start
        XCTAssertFalse(e.takeProbe(now: t0))
        XCTAssertFalse(e.takeProbe(now: t0.addingTimeInterval(LuckgramEndpoints.probeInterval - 1)))
        XCTAssertTrue(e.takeProbe(now: t0.addingTimeInterval(LuckgramEndpoints.probeInterval)))
        e.markWorking(a)
        XCTAssertFalse(e.takeProbe(now: t0.addingTimeInterval(3 * LuckgramEndpoints.probeInterval)))
    }

    func testRewritesServerUrlsToCurrentEntry() {
        let e = ep()
        let img = a + "/v1/media/abc.jpg?sig=1"
        XCTAssertEqual(e.rewrite(img), img)
        e.markWorking(b)
        XCTAssertEqual(e.rewrite(img), b + "/v1/media/abc.jpg?sig=1")
        XCTAssertEqual(e.rewrite("HTTPS://API.LUCKGRAM.CC/v1/x"), b + "/v1/x")
        XCTAssertEqual(e.rewrite("https://api.luckgram.cc.evil.example.com/x"), "https://api.luckgram.cc.evil.example.com/x")
        XCTAssertEqual(e.rewrite("https://media.luckgram.cc/a.jpg"), "https://media.luckgram.cc/a.jpg")
        XCTAssertEqual(e.base(of: a), a)
    }

    func testEntryHosts() {
        let e = ep()
        XCTAssertTrue(e.isEntryHost("API.luckgram.cc"))
        XCTAssertTrue(e.isEntryHost("backup.luckgram.cc"))
        XCTAssertFalse(e.isEntryHost("media.luckgram.cc"))
        XCTAssertFalse(e.isEntryHost(nil))
        XCTAssertEqual(LuckgramEndpoints.host(of: a + ":443/v1"), "api.luckgram.cc")
    }
}
