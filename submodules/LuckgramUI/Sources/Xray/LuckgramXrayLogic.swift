import Foundation

/// specs#119: VLESS / VMess / Trojan / Shadowsocks share links for the built-in Xray core.
///
/// Every node is kept as one canonical share link in the form libXray parses
/// (`scheme://id@host:port?query#name`); v2rayN VMess JSON links, legacy `ss://` links and
/// Clash / mihomo entries are converted to it. The Xray config that turns each node into a
/// loopback SOCKS5 inbound is built here too.
///
/// Foundation only, unit-tested in `LuckgramXrayLogicTests`. Same rules as Android `XrayLogic`.
public enum LuckgramXrayLogic {
    public static let vless = "vless"
    public static let vmess = "vmess"
    public static let trojan = "trojan"
    public static let ss = "ss"

    public struct Node: Equatable {
        public let proto: String
        public let host: String
        public let port: Int
        public let name: String
        /// Canonical share link.
        public let link: String

        /// The link without its name: renaming a node in a subscription keeps it the same node.
        public var key: String {
            return LuckgramXrayLogic.key(link: link)
        }
    }

    public static func key(link: String) -> String {
        if let hash = link.firstIndex(of: "#") {
            return "xray|" + link[..<hash]
        }
        return "xray|" + link
    }

    /// "VLESS", "VMess", "Trojan", "SS".
    public static func label(_ proto: String) -> String {
        switch proto {
        case vless: return "VLESS"
        case vmess: return "VMess"
        case trojan: return "Trojan"
        case ss: return "SS"
        default: return proto.uppercased()
        }
    }

    /// Whether the text starts with a scheme handled here (it may still be incomplete).
    public static func looksLikeLink(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let l = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return l.hasPrefix("vless://") || l.hasPrefix("vmess://") || l.hasPrefix("trojan://") || l.hasPrefix("ss://")
    }

    // MARK: - share links

    /// A share link as a node, or nil when it is not one of the four or is incomplete.
    public static func parse(_ raw: String?) -> Node? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("vmess://") {
            if let n = parseVmessJson(String(text.dropFirst(8))) { return n }
            return parseUrl(vmess, text)
        }
        if lower.hasPrefix("ss://") { return parseSs(text) }
        if lower.hasPrefix("vless://") { return parseUrl(vless, text) }
        if lower.hasPrefix("trojan://") { return parseUrl(trojan, text) }
        return nil
    }

    /// Splits `rest#name` and `rest?query`.
    private static func splitTail(_ s: String) -> (rest: String, query: String, name: String) {
        var rest = s
        var name = ""
        if let h = rest.firstIndex(of: "#") {
            name = decode(String(rest[rest.index(after: h)...]))
            rest = String(rest[..<h])
        }
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        if rest.hasSuffix("/") { rest.removeLast() }
        return (rest, query, name)
    }

    /// `scheme://id@host:port?query#name`: id, host and port are required.
    private static func parseUrl(_ proto: String, _ text: String) -> Node? {
        guard let r = text.range(of: "://") else { return nil }
        let (rest, query, name) = splitTail(String(text[r.upperBound...]))
        guard let at = rest.lastIndex(of: "@"), at > rest.startIndex else { return nil }
        let id = String(rest[..<at])
        guard let hp = hostPort(String(rest[rest.index(after: at)...])), !decode(id).isEmpty, let port = parsePort(hp.1) else { return nil }
        var link = "\(proto)://\(id)@\(hostForUrl(hp.0)):\(port)"
        if !query.isEmpty { link += "?" + query }
        if !name.isEmpty { link += "#" + encode(name) }
        return Node(proto: proto, host: hp.0, port: port, name: name, link: link)
    }

    /// SIP002 (`ss://base64(method:pass)@host:port` or plain `method:pass`) and the legacy `ss://base64(method:pass@host:port)`.
    private static func parseSs(_ text: String) -> Node? {
        let (rest, query, name) = splitTail(String(text.dropFirst(5)))
        if query.lowercased().contains("plugin=") { return nil } // obfs / v2ray-plugin: not in Xray
        var userInfo: String?
        var hostPortText: String
        if let at = rest.lastIndex(of: "@") {
            let u = decode(String(rest[..<at]))
            userInfo = u.contains(":") ? u : base64Text(u)
            hostPortText = String(rest[rest.index(after: at)...])
        } else {
            guard let decoded = base64Text(rest), let at2 = decoded.lastIndex(of: "@"), at2 > decoded.startIndex else { return nil }
            userInfo = String(decoded[..<at2])
            hostPortText = String(decoded[decoded.index(after: at2)...])
        }
        guard let info = userInfo, let colon = info.firstIndex(of: ":"), colon > info.startIndex, info.index(after: colon) < info.endIndex else { return nil }
        guard let hp = hostPort(hostPortText), let port = parsePort(hp.1) else { return nil }
        let link = "ss://" + base64UrlNoPad(Data(info.utf8)) + "@" + hostForUrl(hp.0) + ":\(port)" + (name.isEmpty ? "" : "#" + encode(name))
        return Node(proto: ss, host: hp.0, port: port, name: name, link: link)
    }

    /// v2rayN: `vmess://base64({"add","port","id","net","host","path","tls","sni",...})`.
    private static func parseVmessJson(_ b64: String) -> Node? {
        let body = b64.firstIndex(of: "#").map { String(b64[..<$0]) } ?? b64
        guard let json = base64Text(body), json.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        func str(_ k: String) -> String {
            if let s = obj[k] as? String { return s }
            if let n = obj[k] as? NSNumber { return n.stringValue }
            return ""
        }
        // alterId > 0 is legacy VMess (MD5 auth); Xray only supports AEAD (alterId 0).
        if let aid = Int(str("aid")), aid > 0 { return nil }
        let net = str("net").isEmpty ? "tcp" : str("net")
        var q: [(String, String)] = []
        q.append(("encryption", str("scy").isEmpty ? "auto" : str("scy")))
        let tls = str("tls").lowercased()
        q.append(("security", tls == "tls" ? "tls" : tls == "reality" ? "reality" : "none"))
        putIf(&q, "sni", str("sni"))
        putIf(&q, "fp", str("fp"))
        putIf(&q, "alpn", str("alpn"))
        q.append(("type", net))
        if net == "grpc" {
            putIf(&q, "serviceName", str("path"))
        } else {
            putIf(&q, "host", str("host"))
            putIf(&q, "path", str("path"))
        }
        if net == "tcp" && str("type") == "http" { q.append(("headerType", "http")) }
        guard let link = buildLink(vmess, str("id"), str("add"), parsePort(str("port")) ?? -1, q, str("ps")) else { return nil }
        return parseUrl(vmess, link)
    }

    // MARK: - Clash / mihomo

    /// A Clash / mihomo proxy (nested maps flattened to dotted keys, e.g. `ws-opts.path`,
    /// `ws-opts.headers.Host`) as a canonical share link, or nil when it cannot be used.
    public static func fromClash(_ m: [String: String]) -> String? {
        let type = (m["type"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard let server = m["server"], !server.isEmpty, let port = parsePort(m["port"]) else { return nil }
        let name = m["name"]
        var q: [(String, String)] = []
        switch type {
        case vless:
            q.append(("encryption", nonEmpty(m["encryption"], "none")))
            putIf(&q, "flow", m["flow"])
            security(m, &q)
            guard transport(m, &q) else { return nil }
            return buildLink(vless, m["uuid"], server, port, q, name)
        case vmess:
            if let aid = Int(m["alterId"] ?? ""), aid > 0 { return nil } // legacy MD5 auth
            q.append(("encryption", nonEmpty(m["cipher"], "auto")))
            security(m, &q)
            guard transport(m, &q) else { return nil }
            return buildLink(vmess, m["uuid"], server, port, q, name)
        case trojan:
            q.append(("security", "tls"))
            putIf(&q, "sni", nonEmpty(m["sni"], m["servername"] ?? ""))
            putIf(&q, "fp", m["client-fingerprint"])
            if m["reality-opts.public-key"] != nil {
                q[0] = ("security", "reality")
                putIf(&q, "pbk", m["reality-opts.public-key"])
                putIf(&q, "sid", m["reality-opts.short-id"])
            }
            guard transport(m, &q) else { return nil }
            return buildLink(trojan, m["password"], server, port, q, name)
        case ss:
            if m["plugin"] != nil { return nil } // obfs / v2ray-plugin / shadow-tls: not in Xray
            guard let cipher = m["cipher"], !cipher.isEmpty, let password = m["password"], !password.isEmpty else { return nil }
            return "ss://" + base64UrlNoPad(Data("\(cipher):\(password)".utf8)) + "@" + hostForUrl(server) + ":\(port)"
                + ((name ?? "").isEmpty ? "" : "#" + encode(name!))
        default:
            return nil
        }
    }

    /// tls / reality → security, sni, fp, pbk, sid.
    private static func security(_ m: [String: String], _ q: inout [(String, String)]) {
        let reality = m["reality-opts.public-key"] != nil
        let tls = (m["tls"] ?? "").lowercased() == "true"
        if reality {
            q.append(("security", "reality"))
            putIf(&q, "pbk", m["reality-opts.public-key"])
            putIf(&q, "sid", m["reality-opts.short-id"])
        } else {
            q.append(("security", tls ? "tls" : "none"))
        }
        if tls || reality {
            putIf(&q, "sni", nonEmpty(m["servername"], m["sni"] ?? ""))
            putIf(&q, "fp", m["client-fingerprint"])
        }
    }

    /// network → type, host, path, serviceName. False for a transport Xray cannot use.
    private static func transport(_ m: [String: String], _ q: inout [(String, String)]) -> Bool {
        let network = nonEmpty(m["network"], "tcp").lowercased()
        switch network {
        case "tcp":
            q.append(("type", "tcp"))
        case "ws":
            q.append(("type", "ws"))
            putIf(&q, "host", nonEmpty(m["ws-opts.headers.Host"], m["ws-opts.headers.host"] ?? ""))
            putIf(&q, "path", m["ws-opts.path"])
        case "grpc":
            q.append(("type", "grpc"))
            putIf(&q, "serviceName", m["grpc-opts.grpc-service-name"])
        case "h2", "http":
            q.append(("type", "http"))
            putIf(&q, "path", m["h2-opts.path"])
        case "xhttp":
            q.append(("type", "xhttp"))
            putIf(&q, "host", m["xhttp-opts.host"])
            putIf(&q, "path", m["xhttp-opts.path"])
            putIf(&q, "mode", m["xhttp-opts.mode"])
        default:
            return false
        }
        return true
    }

    private static func buildLink(_ proto: String, _ id: String?, _ host: String, _ port: Int, _ q: [(String, String)], _ name: String?) -> String? {
        guard let id, !id.isEmpty, !host.isEmpty, port > 0 else { return nil }
        var b = "\(proto)://\(encode(id))@\(hostForUrl(host)):\(port)"
        var sep = "?"
        for (k, v) in q {
            b += sep + k + "=" + encode(v)
            sep = "&"
        }
        if let name, !name.isEmpty { b += "#" + encode(name) }
        return b
    }

    // MARK: - Xray config

    /// One node to run: its local SOCKS5 port and the outbound libXray built from its link.
    public struct Run {
        public let localPort: Int
        public let outboundJson: String

        public init(localPort: Int, outboundJson: String) {
            self.localPort = localPort
            self.outboundJson = outboundJson
        }
    }

    /// The whole Xray config: one `127.0.0.1` SOCKS5 inbound per node, with the same username /
    /// password on each, routed to that node's outbound. Anything unmatched is dropped.
    public static func buildConfig(_ runs: [Run], user: String, password: String, logLevel: String = "warning") -> String? {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = [["tag": "block", "protocol": "blackhole"]]
        var rules: [[String: Any]] = []
        for (i, r) in runs.enumerated() {
            guard var ob = (try? JSONSerialization.jsonObject(with: Data(r.outboundJson.utf8))) as? [String: Any] else { return nil }
            let inTag = "in-\(i)"
            let outTag = "out-\(i)"
            inbounds.append([
                "tag": inTag,
                "listen": "127.0.0.1",
                "port": r.localPort,
                "protocol": "socks",
                "settings": [
                    "auth": "password",
                    "accounts": [["user": user, "pass": password]],
                    "udp": true,
                    "ip": "127.0.0.1"
                ] as [String: Any]
            ])
            ob["tag"] = outTag
            ob.removeValue(forKey: "sendThrough")
            outbounds.append(ob)
            rules.append(["type": "field", "inboundTag": [inTag], "outboundTag": outTag])
        }
        let config: [String: Any] = [
            "log": ["loglevel": logLevel, "access": "none"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "AsIs", "rules": rules] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The first outbound of a `convertShareLinksToXrayJson` result, or nil.
    public static func firstOutbound(_ converted: String) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(converted.utf8))) as? [String: Any],
              let a = obj["outbounds"] as? [Any], let first = a.first,
              let data = try? JSONSerialization.data(withJSONObject: first) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Desktop #125 / #126: Xray 26 refuses VLESS / Trojan without TLS, Reality or VLESS encryption
    /// unless the server is a private address ("... is prohibited unless the server address is a
    /// private IP or domain"), and one such outbound makes the whole config fail: no node works.
    /// True for such an outbound (as libXray built it; libXray already makes every Trojan TLS, so in
    /// practice plain VLESS). Never given to the core; the list says why. Same as Android.
    public static func refusedByCore(_ outboundJson: String) -> Bool {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(outboundJson.utf8))) as? [String: Any],
              let proto = o["protocol"] as? String, proto == vless || proto == trojan,
              let settings = o["settings"] as? [String: Any] else { return false }
        let stream = o["streamSettings"] as? [String: Any]
        let security = ((stream?["security"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if !security.isEmpty && security != "none" { return false }
        // Flat (libXray 26: address / port / id / encryption) or vnext / servers.
        var server = settings
        if settings["address"] == nil, let list = settings[proto == vless ? "vnext" : "servers"] as? [[String: Any]], let first = list.first {
            server = first
        }
        if proto == vless {
            var encryption = (server["encryption"] as? String) ?? (settings["encryption"] as? String) ?? ""
            if let users = server["users"] as? [[String: Any]], let user = users.first, let e = user["encryption"] as? String {
                encryption = e
            }
            encryption = encryption.trimmingCharacters(in: .whitespaces).lowercased()
            if !encryption.isEmpty && encryption != "none" { return false }
        }
        return !isPrivateAddress((server["address"] as? String) ?? "")
    }

    /// Loopback, private (10/8, 172.16/12, 192.168/16), link-local, IPv6 ULA / link-local / ::1,
    /// localhost (checked against xray 26.10.31 `run -test`). Other names count as public: xray
    /// accepts .local / .lan too, missing one only leaves a node unused.
    public static func isPrivateAddress(_ host: String) -> Bool {
        var h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h == "localhost" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) {
            let b = parts.map { Int($0) ?? 999 }
            if b.contains(where: { $0 > 255 }) { return false }
            return b[0] == 10 || b[0] == 127
                || (b[0] == 172 && b[1] >= 16 && b[1] <= 31)
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        }
        guard h.contains(":") else { return false }
        if h == "::1" { return true }
        let first = h.prefix(while: { $0 != ":" })
        guard first.count == 4, let v = Int(first, radix: 16) else { return false }
        return (v & 0xFE00) == 0xFC00 || (v & 0xFFC0) == 0xFE80
    }

    /// `n` free ports counting up from `base` (wrapping inside 20000–59999), skipping `used`.
    public static func pickPorts(base: Int, used: Set<Int>, count n: Int) -> [Int] {
        var out: [Int] = []
        var p = (base < 20000 || base > 59999) ? 20000 : base
        var tries = 0
        while out.count < n && tries < 40000 {
            if !used.contains(p) && !out.contains(p) { out.append(p) }
            p = p >= 59999 ? 20000 : p + 1
            tries += 1
        }
        return out
    }

    // MARK: - helpers

    private static func hostPort(_ s: String) -> (String, String)? {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let after = s[s.index(after: close)...]
            guard after.hasPrefix(":"), after.count > 1 else { return nil }
            return (String(s[s.index(after: s.startIndex)..<close]), String(after.dropFirst()))
        }
        guard let colon = s.lastIndex(of: ":"), colon > s.startIndex else { return nil }
        return (String(s[..<colon]), String(s[s.index(after: colon)...]))
    }

    private static func hostForUrl(_ host: String) -> String {
        return host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    static func parsePort(_ s: String?) -> Int? {
        guard let s, let p = Int(s.trimmingCharacters(in: .whitespaces)), p > 0, p < 65536 else { return nil }
        return p
    }

    private static func nonEmpty(_ a: String?, _ b: String) -> String {
        if let a, !a.isEmpty { return a }
        return b
    }

    private static func putIf(_ q: inout [(String, String)], _ k: String, _ v: String?) {
        if let v, !v.isEmpty { q.append((k, v)) }
    }

    static func decode(_ s: String) -> String {
        return s.removingPercentEncoding ?? s
    }

    /// Like Java's `URLEncoder` (letters, digits, `.-*_` kept) with spaces as `%20`.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: ".-*_")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// Base64 or base64url, padding optional, as UTF-8 text; nil when invalid.
    static func base64Text(_ s: String) -> String? {
        var clean = s.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if let eq = clean.firstIndex(of: "=") { clean = String(clean[..<eq]) }
        if clean.isEmpty || clean.count % 4 == 1 { return nil }
        var bytes: [UInt8] = []
        var buf = 0
        var bits = 0
        for c in clean {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buf = ((buf << 6) | v) & 0xFFFFFF
            bits += 6
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buf >> bits) & 0xff))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func base64UrlNoPad(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
