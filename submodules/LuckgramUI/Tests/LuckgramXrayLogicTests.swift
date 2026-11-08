import XCTest
@testable import LuckgramUI

/// specs#119: share links, Clash conversion, Xray config (same cases as Android `XrayLogicTest`).
final class LuckgramXrayLogicTests: XCTestCase {
    typealias X = LuckgramXrayLogic
    static let uuid = "1b0c5e6a-0000-4000-8000-000000000001"

    func testVlessLink() {
        let n = X.parse("vless://\(Self.uuid)@edge.example.com:443?encryption=none&security=tls&sni=edge.example.com&type=ws&path=%2Fws#SG%201")!
        XCTAssertEqual(n.proto, X.vless)
        XCTAssertEqual(n.host, "edge.example.com")
        XCTAssertEqual(n.port, 443)
        XCTAssertEqual(n.name, "SG 1")
        XCTAssertTrue(n.link.hasPrefix("vless://\(Self.uuid)@edge.example.com:443?"))
        XCTAssertTrue(n.link.hasSuffix("#SG%201"))
        let renamed = X.parse(n.link.replacingOccurrences(of: "#SG%201", with: "#other"))!
        XCTAssertEqual(n.key, renamed.key)
    }

    func testIncompleteLinks() {
        XCTAssertNil(X.parse("vless://edge.example.com:443"))
        XCTAssertNil(X.parse("vless://\(Self.uuid)@edge.example.com"))
        XCTAssertNil(X.parse("trojan://@h:443"))
        XCTAssertNil(X.parse("vless://\(Self.uuid)@h:70000"))
        XCTAssertNil(X.parse("http://example.com"))
    }

    func testIpv6Host() {
        let n = X.parse("trojan://pw@[2001:db8::1]:443?security=tls#t")!
        XCTAssertEqual(n.host, "2001:db8::1")
        XCTAssertTrue(n.link.contains("@[2001:db8::1]:443"))
    }

    private func vmessLink(_ o: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return "vmess://" + data.base64EncodedString()
    }

    func testVmessV2rayNJson() {
        var o: [String: Any] = ["v": "2", "ps": "US 1", "add": "v.example.com", "port": "8443", "id": Self.uuid, "aid": "0",
                                "net": "ws", "host": "cdn.example.com", "path": "/v", "tls": "tls", "sni": "cdn.example.com"]
        let n = X.parse(vmessLink(o))!
        XCTAssertEqual(n.proto, X.vmess)
        XCTAssertEqual(n.host, "v.example.com")
        XCTAssertEqual(n.port, 8443)
        XCTAssertEqual(n.name, "US 1")
        XCTAssertTrue(n.link.hasPrefix("vmess://\(Self.uuid)@v.example.com:8443?encryption=auto&security=tls&sni=cdn.example.com&type=ws&host=cdn.example.com&path=%2Fv"), n.link)
        o["aid"] = "64"
        XCTAssertNil(X.parse(vmessLink(o)))
    }

    func testShadowsocksForms() {
        let userInfo = X.base64UrlNoPad(Data("aes-128-gcm:pass".utf8))
        let sip002 = X.parse("ss://\(userInfo)@198.51.100.5:8388#SS%201")!
        XCTAssertEqual(sip002.proto, X.ss)
        XCTAssertEqual(sip002.port, 8388)
        XCTAssertEqual(sip002.name, "SS 1")
        let plain = X.parse("ss://aes-128-gcm:pass@198.51.100.5:8388")!
        XCTAssertEqual(sip002.key, plain.key)
        let legacy = Data("aes-128-gcm:pass@198.51.100.5:8388".utf8).base64EncodedString()
        XCTAssertEqual(sip002.key, X.parse("ss://\(legacy)#x")!.key)
        XCTAssertNil(X.parse("ss://\(userInfo)@198.51.100.5:8388/?plugin=obfs-local%3Bobfs%3Dhttp"))
    }

    func testClashVlessWsTls() {
        let link = X.fromClash([
            "name": "SG·hk 1001", "type": "vless", "server": "agg.example.com", "port": "443",
            "uuid": Self.uuid, "tls": "true", "servername": "sni.example.com", "client-fingerprint": "chrome",
            "network": "ws", "ws-opts.path": "/ray?ed=2048", "ws-opts.headers.Host": "sni.example.com", "udp": "true",
        ])
        XCTAssertEqual(link, "vless://\(Self.uuid)@agg.example.com:443?encryption=none&security=tls&sni=sni.example.com&fp=chrome&type=ws&host=sni.example.com&path=%2Fray%3Fed%3D2048#SG%C2%B7hk%201001")
        let n = X.parse(link)!
        XCTAssertEqual(n.name, "SG·hk 1001")
        XCTAssertEqual(n.link, link)
    }

    func testClashReality() {
        let link = X.fromClash([
            "name": "r", "type": "vless", "server": "r.example.com", "port": "443", "uuid": Self.uuid,
            "flow": "xtls-rprx-vision", "tls": "true", "servername": "www.example.com",
            "reality-opts.public-key": "PUBKEY", "reality-opts.short-id": "ab12", "client-fingerprint": "chrome",
        ])!
        for part in ["flow=xtls-rprx-vision", "security=reality", "pbk=PUBKEY", "sid=ab12", "sni=www.example.com", "type=tcp"] {
            XCTAssertTrue(link.contains(part), link)
        }
    }

    func testClashOthers() {
        let vmess = X.fromClash(["name": "m", "type": "vmess", "server": "m.example.com", "port": "443", "uuid": Self.uuid,
                                 "alterId": "0", "cipher": "auto", "tls": "true", "network": "grpc", "grpc-opts.grpc-service-name": "svc"])!
        XCTAssertTrue(vmess.hasPrefix("vmess://\(Self.uuid)@m.example.com:443?encryption=auto&security=tls&type=grpc&serviceName=svc"), vmess)
        XCTAssertNil(X.fromClash(["type": "vmess", "server": "m", "port": "443", "uuid": Self.uuid, "alterId": "64"]))

        XCTAssertEqual(X.fromClash(["name": "t", "type": "trojan", "server": "t.example.com", "port": "443", "password": "pw", "sni": "t.example.com"]),
                       "trojan://pw@t.example.com:443?security=tls&sni=t.example.com&type=tcp#t")

        let ss = X.fromClash(["name": "s", "type": "ss", "server": "198.51.100.9", "port": "8388", "cipher": "chacha20-ietf-poly1305", "password": "pw"])
        XCTAssertEqual(X.parse(ss)?.proto, X.ss)
        XCTAssertNil(X.fromClash(["type": "ss", "server": "h", "port": "1", "cipher": "aes-128-gcm", "password": "p", "plugin": "obfs"]))

        XCTAssertNil(X.fromClash(["type": "hysteria2", "server": "h", "port": "443", "password": "p"]))
        XCTAssertNil(X.fromClash(["type": "vless", "server": "h", "port": "443", "uuid": Self.uuid, "network": "kcp"]))
        XCTAssertNil(X.fromClash(["type": "vless", "server": "h", "port": "443"]))
    }

    func testConfig() throws {
        let ob = "{\"protocol\":\"vless\",\"tag\":\"name from link\",\"settings\":{\"address\":\"a\",\"port\":443}}"
        let json = X.buildConfig([X.Run(localPort: 31001, outboundJson: ob), X.Run(localPort: 31002, outboundJson: ob)], user: "lg", password: "secret")!
        let c = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let inbounds = c["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds.count, 2)
        XCTAssertEqual(inbounds[0]["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(inbounds[0]["port"] as? Int, 31001)
        XCTAssertEqual(inbounds[0]["protocol"] as? String, "socks")
        let settings = inbounds[0]["settings"] as! [String: Any]
        XCTAssertEqual(settings["auth"] as? String, "password")
        XCTAssertEqual((settings["accounts"] as! [[String: Any]])[0]["pass"] as? String, "secret")
        let outbounds = c["outbounds"] as! [[String: Any]]
        XCTAssertEqual(outbounds[0]["tag"] as? String, "block")
        XCTAssertEqual(outbounds[2]["tag"] as? String, "out-1")
        let rule = ((c["routing"] as! [String: Any])["rules"] as! [[String: Any]])[1]
        XCTAssertEqual((rule["inboundTag"] as! [String])[0], "in-1")
        XCTAssertEqual(rule["outboundTag"] as? String, "out-1")
        XCTAssertNil(X.buildConfig([X.Run(localPort: 1, outboundJson: "nope")], user: "u", password: "p"))
    }

    func testFirstOutbound() {
        XCTAssertTrue(X.firstOutbound("{\"outbounds\":[{\"protocol\":\"vless\"},{\"protocol\":\"x\"}]}")!.contains("vless"))
        XCTAssertNil(X.firstOutbound("{\"outbounds\":[]}"))
        XCTAssertNil(X.firstOutbound("nope"))
    }

    func testPorts() {
        XCTAssertEqual(X.pickPorts(base: 30000, used: [30001], count: 3), [30000, 30002, 30003])
        XCTAssertEqual(X.pickPorts(base: 59999, used: [], count: 2), [59999, 20000])
        XCTAssertEqual(X.pickPorts(base: 5, used: [], count: 1), [20000])
    }

    func testBase64() {
        for s in ["f", "fo", "foo", "foob", "fooba", "foobar", "中文"] {
            let d = Data(s.utf8)
            let url = X.base64UrlNoPad(d)
            XCTAssertEqual(X.base64Text(url), s)
            XCTAssertEqual(X.base64Text(d.base64EncodedString()), s)
        }
        XCTAssertNil(X.base64Text("@@@"))
        XCTAssertFalse(X.looksLikeLink("socks5://h:1"))
        XCTAssertTrue(X.looksLikeLink(" VLESS://x"))
    }
}
