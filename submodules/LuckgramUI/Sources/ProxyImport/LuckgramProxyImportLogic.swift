import Foundation

/// specs#118: what a scanned or typed text means for the proxy list, and the proxies in a
/// mihomo / Clash subscription. Only SOCKS5 (and MTProto from tg links) can be used by the app;
/// everything else in a subscription is counted as skipped.
///
/// Foundation only, unit-tested in `LuckgramProxyImportLogicTests`. Same rules as Android
/// `ProxyImportLogic`.
public enum LuckgramProxyImportLogic {
    public enum Kind: Equatable {
        case unknown
        case proxy
        case subscription
    }

    public static let typeSocks5 = "socks5"
    public static let typeMtproto = "mtproto"
    /// Largest subscription accepted.
    public static let maxBytes = 2 * 1024 * 1024

    public struct Entry: Equatable, Hashable {
        public let type: String
        public let host: String
        public let port: Int
        public let user: String
        public let password: String
        public let secret: String

        public init(type: String, host: String, port: Int, user: String?, password: String?, secret: String?) {
            self.type = type
            self.host = host.trimmingCharacters(in: .whitespaces)
            self.port = port
            self.user = user ?? ""
            self.password = password ?? ""
            self.secret = secret ?? ""
        }

        /// Identity used to recognise the same proxy across refreshes.
        public var key: String {
            return "\(type)|\(host.lowercased())|\(port)|\(user)|\(password)|\(secret)"
        }

        public static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.key == rhs.key }
        public func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    public struct Result {
        public let proxies: [Entry]
        public let skipped: Int
    }

    public struct Diff {
        public var add: [Entry] = []
        public var remove: [String] = []
    }

    // MARK: - input kind

    public static func kind(_ raw: String?) -> Kind {
        guard let raw else { return .unknown }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.contains("\n") || text.contains(" ") { return .unknown }
        if parseLink(text) != nil { return .proxy }
        let lower = text.lowercased()
        if (lower.hasPrefix("https://") || lower.hasPrefix("http://")) && !isTelegramLink(lower) && hostOf(text) != nil {
            return .subscription
        }
        return .unknown
    }

    static func isTelegramLink(_ lower: String) -> Bool {
        guard let host = hostOf(lower) else { return false }
        return host == "t.me" || host == "telegram.me" || host == "telegram.dog" || host.hasSuffix(".t.me")
    }

    /// Host of an http(s) URL, or nil.
    public static func hostOf(_ url: String) -> String? {
        guard let r = url.range(of: "://") else { return nil }
        var rest = String(url[r.upperBound...])
        if let i = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = String(rest[..<i]) }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]"), rest.distance(from: rest.startIndex, to: close) > 1 else { return nil }
            return String(rest[rest.index(after: rest.startIndex)..<close])
        }
        if let colon = rest.lastIndex(of: ":") { rest = String(rest[..<colon]) }
        return rest.isEmpty ? nil : rest.lowercased()
    }

    // MARK: - single links

    /// `tg://socks|proxy?…`, `https://t.me/socks|proxy?…` (also telegram.me / telegram.dog) or
    /// `socks5://[user:pass@]host:port` (`socks://`, `socks5h://`). Nil when none or incomplete.
    public static func parseLink(_ raw: String?) -> Entry? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        for p in ["socks5h://", "socks5://", "socks://"] where lower.hasPrefix(p) {
            return parseSocksUrl(String(text.dropFirst(p.count)))
        }
        var path: String?
        var query = ""
        if lower.hasPrefix("tg:") {
            var rest = String(text.dropFirst(3))
            if rest.hasPrefix("//") { rest = String(rest.dropFirst(2)) }
            if let q = rest.firstIndex(of: "?") {
                path = String(rest[..<q]).lowercased(); query = String(rest[rest.index(after: q)...])
            } else {
                path = rest.lowercased()
            }
        } else if lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("t.me/") || lower.hasPrefix("telegram.me/") {
            let url = lower.hasPrefix("http") ? text : "https://" + text
            guard isTelegramLink(url.lowercased()), let r = url.range(of: "://") else { return nil }
            var rest = String(url[r.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            rest = String(rest[rest.index(after: slash)...])
            if let q = rest.firstIndex(of: "?") {
                path = String(rest[..<q]).lowercased(); query = String(rest[rest.index(after: q)...])
            } else {
                path = rest.lowercased()
            }
        }
        guard var p = path else { return nil }
        if p.hasSuffix("/") { p.removeLast() }
        guard p == "socks" || p == "proxy" else { return nil }
        let params = queryParams(query)
        guard let server = params["server"], !server.isEmpty, let port = parsePort(params["port"]) else { return nil }
        if p == "socks" {
            return Entry(type: typeSocks5, host: server, port: port, user: params["user"], password: params["pass"], secret: nil)
        }
        guard let secret = params["secret"], !secret.isEmpty else { return nil }
        return Entry(type: typeMtproto, host: server, port: port, user: nil, password: nil, secret: secret)
    }

    private static func parseSocksUrl(_ rest0: String) -> Entry? {
        var auth = rest0
        if let i = auth.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { auth = String(auth[..<i]) }
        var user: String?
        var pass: String?
        if let at = auth.lastIndex(of: "@") {
            let cred = String(auth[..<at])
            auth = String(auth[auth.index(after: at)...])
            if let c = cred.firstIndex(of: ":") {
                user = decode(String(cred[..<c])); pass = decode(String(cred[cred.index(after: c)...]))
            } else {
                user = decode(cred); pass = ""
            }
        }
        let host: String
        var portStr: String?
        if auth.hasPrefix("[") {
            guard let close = auth.firstIndex(of: "]") else { return nil }
            host = String(auth[auth.index(after: auth.startIndex)..<close])
            let after = auth[auth.index(after: close)...]
            if after.hasPrefix(":") { portStr = String(after.dropFirst()) }
        } else {
            guard let colon = auth.lastIndex(of: ":") else { return nil }
            host = String(auth[..<colon]); portStr = String(auth[auth.index(after: colon)...])
        }
        guard !host.isEmpty, let port = parsePort(portStr) else { return nil }
        return Entry(type: typeSocks5, host: host, port: port, user: user, password: pass, secret: nil)
    }

    private static func queryParams(_ query0: String) -> [String: String] {
        var query = query0
        if let h = query.firstIndex(of: "#") { query = String(query[..<h]) }
        var out: [String: String] = [:]
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = decode(String(kv[0])).lowercased()
            let v = kv.count > 1 ? decode(String(kv[1])) : ""
            if out[k] == nil { out[k] = v }
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        return s.removingPercentEncoding ?? s
    }

    static func parsePort(_ s: String?) -> Int? {
        guard let s, let p = Int(s.trimmingCharacters(in: .whitespaces)), p > 0, p < 65536 else { return nil }
        return p
    }

    // MARK: - subscriptions

    /// Proxies in a subscription body: a Clash / mihomo YAML config, or a (base64) list of links.
    public static func parseSubscription(_ body: String) -> Result {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.hasPrefix("proxies:") }) {
            return parseClash(text)
        }
        if let decoded = decodeBase64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parseLinkList(decoded)
        }
        return parseLinkList(text)
    }

    static func decodeBase64(_ s: String) -> String? {
        if s.isEmpty || s.contains("://") { return nil }
        var clean = s.filter { !$0.isWhitespace }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        guard clean.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        clean = clean.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while clean.count % 4 != 0 { clean += "=" }
        guard let data = Data(base64Encoded: clean) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseLinkList(_ text: String) -> Result {
        var found: [Entry] = []
        var seen = Set<String>()
        var skipped = 0
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || (!l.contains("://") && !l.hasPrefix("tg:")) { continue }
            if let e = parseLink(l) {
                if seen.insert(e.key).inserted { found.append(e) }
            } else {
                skipped += 1
            }
        }
        return Result(proxies: found, skipped: skipped)
    }

    private static func leadingSpaces(_ s: Substring) -> Int {
        return s.prefix(while: { $0 == " " }).count
    }

    /// The `proxies:` list of a Clash / mihomo config, block or flow style.
    static func parseClash(_ text: String) -> Result {
        var items: [[String: String]] = []
        var inProxies = false
        var cur: Int?
        var itemIndent = -1
        var keyIndent = -1
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let indent = leadingSpaces(line)
            if indent == 0 && !t.hasPrefix("-") {
                inProxies = t.hasPrefix("proxies:")
                cur = nil; itemIndent = -1
                continue
            }
            if !inProxies { continue }
            if t.hasPrefix("- ") || t == "-" {
                if itemIndent < 0 { itemIndent = indent }
                if indent == itemIndent {
                    let after = t.dropFirst()
                    let rest = after.trimmingCharacters(in: .whitespaces)
                    keyIndent = indent + 1 + leadingSpaces(after)
                    var m: [String: String] = [:]
                    if rest.hasPrefix("{") {
                        parseFlowMap(rest, into: &m)
                        items.append(m); cur = nil
                    } else {
                        if !rest.isEmpty { putPair(rest, into: &m) }
                        items.append(m); cur = items.count - 1
                    }
                    continue
                }
            }
            if let c = cur, indent == keyIndent, !t.hasPrefix("-") {
                putPair(t, into: &items[c])
            }
        }
        var found: [Entry] = []
        var seen = Set<String>()
        var skipped = 0
        for m in items {
            if let e = fromClash(m) {
                if seen.insert(e.key).inserted { found.append(e) }
            } else {
                skipped += 1
            }
        }
        return Result(proxies: found, skipped: skipped)
    }

    private static func fromClash(_ m: [String: String]) -> Entry? {
        guard let type = m["type"], type.lowercased() == "socks5" else { return nil }
        if let tls = m["tls"], tls.lowercased() == "true" { return nil } // Telegram has no SOCKS5 over TLS
        guard let server = m["server"], !server.isEmpty, let port = parsePort(m["port"]) else { return nil }
        return Entry(type: typeSocks5, host: server, port: port, user: m["username"], password: m["password"], secret: nil)
    }

    private static func putPair(_ t: String, into m: inout [String: String]) {
        guard let colon = keyColon(t), colon > 0 else { return }
        let chars = Array(t)
        let key = unquote(String(chars[..<colon]).trimmingCharacters(in: .whitespaces))
        let value = String(chars[(colon + 1)...]).trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value.hasPrefix("{") || value.hasPrefix("[") { return } // nested
        m[key] = unquote(stripComment(value))
    }

    /// Index of the ':' ending a key (outside quotes, followed by a space or the end).
    private static func keyColon(_ t: String) -> Int? {
        let chars = Array(t)
        var quote: Character?
        for i in 0..<chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ":" && (i + 1 == chars.count || chars[i + 1] == " ") {
                return i
            }
        }
        return nil
    }

    private static func stripComment(_ v: String) -> String {
        if v.hasPrefix("\"") || v.hasPrefix("'") { return v }
        if let r = v.range(of: " #") { return String(v[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return v
    }

    /// `{a: 1, b: "x, y", c: {d: e}}` → a, b (nested maps skipped).
    static func parseFlowMap(_ s: String, into m: inout [String: String]) {
        guard let start = s.firstIndex(of: "{") else { return }
        var depth = 0
        var quote: Character?
        var part = ""
        for c in s[s.index(after: start)...] {
            if let q = quote {
                part.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" {
                quote = c; part.append(c)
            } else if c == "{" || c == "[" {
                depth += 1; part.append(c)
            } else if c == "}" || c == "]" {
                if depth == 0 {
                    putPair(part.trimmingCharacters(in: .whitespaces), into: &m)
                    return
                }
                depth -= 1; part.append(c)
            } else if c == "," && depth == 0 {
                putPair(part.trimmingCharacters(in: .whitespaces), into: &m)
                part = ""
            } else {
                part.append(c)
            }
        }
        putPair(part.trimmingCharacters(in: .whitespaces), into: &m)
    }

    static func unquote(_ v: String) -> String {
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            return String(v.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
            return String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return v
    }

    // MARK: - refresh

    /// Proxies now in the subscription that are not in the list yet are added; keys imported before
    /// that are gone are removed. `existing` are the keys of every proxy in the list.
    public static func diff(previouslyImported: Set<String>, now: [Entry], existing: Set<String>) -> Diff {
        var d = Diff()
        let nowKeys = Set(now.map { $0.key })
        for e in now where !existing.contains(e.key) {
            d.add.append(e)
        }
        for k in previouslyImported.sorted() where !nowKeys.contains(k) {
            d.remove.append(k)
        }
        return d
    }
}
