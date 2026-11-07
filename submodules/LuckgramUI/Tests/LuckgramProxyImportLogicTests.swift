import XCTest
@testable import LuckgramUI

/// specs#118: proxy links, subscription parsing and refresh diff (same cases as Android).
final class LuckgramProxyImportLogicTests: XCTestCase {
    typealias L = LuckgramProxyImportLogic

    func testKinds() {
        XCTAssertEqual(L.kind("tg://socks?server=1.2.3.4&port=1080"), .proxy)
        XCTAssertEqual(L.kind(" https://t.me/proxy?server=a.b&port=443&secret=ee00 "), .proxy)
        XCTAssertEqual(L.kind("socks5://u:p@1.2.3.4:1080"), .proxy)
        XCTAssertEqual(L.kind("https://agg.example.com/clash/123"), .subscription)
        XCTAssertEqual(L.kind("http://10.0.0.1:8080/sub"), .subscription)
        XCTAssertEqual(L.kind("https://t.me/durov"), .unknown)
        XCTAssertEqual(L.kind("tg://socks?server=1.2.3.4"), .unknown)
        XCTAssertEqual(L.kind("hello world"), .unknown)
        XCTAssertEqual(L.kind(nil), .unknown)
    }

    func testTgLinks() {
        let e = L.parseLink("tg://socks?server=38.182.96.3&port=20201&user=lg%20sg&pass=a%2Bb%26c")!
        XCTAssertEqual(e.type, L.typeSocks5)
        XCTAssertEqual(e.host, "38.182.96.3")
        XCTAssertEqual(e.port, 20201)
        XCTAssertEqual(e.user, "lg sg")
        XCTAssertEqual(e.password, "a+b&c")
        let m = L.parseLink("https://t.me/proxy?server=mtp.example.org&port=443&secret=eeabcdef")!
        XCTAssertEqual(m.type, L.typeMtproto)
        XCTAssertEqual(m.secret, "eeabcdef")
        XCTAssertEqual(L.parseLink("telegram.me/socks?server=example.com&port=1")?.host, "example.com")
        XCTAssertNil(L.parseLink("tg://proxy?server=a&port=1"))
        XCTAssertNil(L.parseLink("tg://socks?server=a&port=99999"))
        XCTAssertNil(L.parseLink("https://example.com/socks?server=a&port=1"))
    }

    func testSocksUrls() {
        let e = L.parseLink("socks5://us%40er:p%3Ass@proxy.example.com:1080/")!
        XCTAssertEqual(e.user, "us@er")
        XCTAssertEqual(e.password, "p:ss")
        XCTAssertEqual(e.host, "proxy.example.com")
        XCTAssertEqual(e.port, 1080)
        let v6 = L.parseLink("socks5h://[2001:db8::1]:1080")!
        XCTAssertEqual(v6.host, "2001:db8::1")
        XCTAssertEqual(v6.user, "")
        XCTAssertEqual(L.parseLink("socks://h:1081")?.port, 1081)
        XCTAssertNil(L.parseLink("socks5://host-without-port"))
    }

    static let clash = [
        "mixed-port: 7890",
        "proxies:",
        "  - {name: 'SG·vless', type: vless, server: agg.example.com, port: 443, uuid: x, ws-opts: {path: /a, headers: {Host: agg.example.com}}}",
        "  - {name: \"s5, flow\", type: socks5, server: 198.51.100.24, port: 1080, username: u1, password: 'p, 1'}",
        "  - name: s5-block",
        "    type: socks5",
        "    server: '198.51.100.77'",
        "    port: 1081",
        "    username: \"u2\"",
        "    password: p2 # comment",
        "    udp: true",
        "  - name: s5-tls",
        "    type: socks5",
        "    server: 192.0.2.1",
        "    port: 443",
        "    tls: true",
        "  - name: ss",
        "    type: ss",
        "    server: 192.0.2.2",
        "    port: 8388",
        "    plugin-opts:",
        "      mode: websocket",
        "      type: socks5",
        "proxy-groups:",
        "  - {name: g, type: select, proxies: [s5-block]}",
        "rules:",
        "  - MATCH,g",
    ].joined(separator: "\n")

    func testClashOnlySocks5() {
        let r = L.parseSubscription(Self.clash)
        XCTAssertEqual(r.proxies.count, 2)
        XCTAssertEqual(r.proxies[0].host, "198.51.100.24")
        XCTAssertEqual(r.proxies[0].password, "p, 1")
        XCTAssertEqual(r.proxies[1].host, "198.51.100.77")
        XCTAssertEqual(r.proxies[1].port, 1081)
        XCTAssertEqual(r.proxies[1].user, "u2")
        XCTAssertEqual(r.proxies[1].password, "p2")
        XCTAssertEqual(r.skipped, 3)
    }

    func testAllVless() {
        let r = L.parseSubscription("proxies:\n- {name: a, type: vless, server: x, port: 443}\n- {name: b, type: vless, server: y, port: 443}\n")
        XCTAssertEqual(r.proxies.count, 0)
        XCTAssertEqual(r.skipped, 2)
    }

    func testBase64LinkList() {
        let list = "tg://socks?server=198.51.100.1&port=1080\nvless://abc@x:443\nsocks5://u:p@198.51.100.2:1080\n\n# c\nsocks5://u:p@198.51.100.2:1080\n"
        let b64 = Data(list.utf8).base64EncodedString()
        let r = L.parseSubscription(b64)
        XCTAssertEqual(r.proxies.count, 2)
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(L.parseSubscription(list).proxies.count, 2)
        let noPad = b64.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(L.parseSubscription(noPad).proxies.count, 2)
    }

    func testRefreshDiff() {
        let a = L.Entry(type: L.typeSocks5, host: "198.51.100.1", port: 1, user: nil, password: nil, secret: nil)
        let b = L.Entry(type: L.typeSocks5, host: "198.51.100.2", port: 1, user: nil, password: nil, secret: nil)
        let c = L.Entry(type: L.typeSocks5, host: "198.51.100.3", port: 1, user: nil, password: nil, secret: nil)
        let d = L.diff(previouslyImported: [a.key, b.key], now: [b, c], existing: [a.key, b.key])
        XCTAssertEqual(d.add, [c])
        XCTAssertEqual(d.remove, [a.key])
        let d2 = L.diff(previouslyImported: [], now: [b, c], existing: [c.key])
        XCTAssertEqual(d2.add, [b])
        XCTAssertTrue(d2.remove.isEmpty)
    }

    func testOwnership() {
        let a = L.Entry(type: L.typeSocks5, host: "198.51.100.1", port: 1, user: nil, password: nil, secret: nil)
        let b = L.Entry(type: L.typeSocks5, host: "198.51.100.2", port: 1, user: nil, password: nil, secret: nil)
        let c = L.Entry(type: L.typeSocks5, host: "198.51.100.3", port: 1, user: nil, password: nil, secret: nil)
        let first = L.diff(previouslyImported: [], now: [a, b], existing: [a.key])
        XCTAssertEqual(L.owned(previouslyOwned: [], now: [a, b], diff: first), [b.key])
        let second = L.diff(previouslyImported: [b.key], now: [a, b, c], existing: [a.key, b.key])
        XCTAssertEqual(L.owned(previouslyOwned: [b.key], now: [a, b, c], diff: second), [b.key, c.key])
    }

    func testHosts() {
        XCTAssertEqual(L.hostOf("https://agg.example.com/clash/1?x=y"), "agg.example.com")
        XCTAssertEqual(L.hostOf("https://u:p@A.B:8443/"), "a.b")
        XCTAssertNil(L.hostOf("nope"))
    }
}
