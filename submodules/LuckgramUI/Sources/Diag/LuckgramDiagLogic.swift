import Foundation

/// specs#72: pure parts of the network diagnostics (Foundation only, unit tested on Linux; same
/// rules as Android `org.telegram.luckgram.diag`).

/// How a Luckgram API request leaves the device, given the in-app Telegram proxy. Only a SOCKS5
/// proxy can carry HTTP; MTProto and web proxies can't, so those requests go direct and the
/// diagnostic log says so.
public enum LuckgramProxyRoute {
    public static let direct = "direct"
    public static let socks5 = "socks5"
    public static let mtprotoDirect = "mtproto-direct"
    public static let webDirect = "web-direct"

    /// - Parameter type: `SOCKS5`, `MTPROTO` or `WEB`; nil if no proxy is set.
    public static func decide(enabled: Bool, type: String?, host: String?, port: Int) -> String {
        guard enabled, let type else {
            return direct
        }
        switch type {
        case "SOCKS5":
            let valid = !(host ?? "").trimmingCharacters(in: .whitespaces).isEmpty && port > 0 && port < 65536
            return valid ? socks5 : direct
        case "MTPROTO":
            return mtprotoDirect
        case "WEB":
            return webDirect
        default:
            return direct
        }
    }
}

/// Line format of the local diagnostic log and how old lines are dropped. One line per Luckgram API
/// request or failed Telegram request. Only metadata: no message text, prompts, tokens, phone
/// numbers, query strings or full URLs.
public enum LuckgramDiagLog {
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    public static let maxBytes = 2 * 1024 * 1024

    private static let maxField = 64

    public struct Entry {
        public var timeMs: Int64 = 0
        /// Feature or AI task, e.g. `summary`, `chat`, `media`.
        public var feature: String?
        public var method: String?
        /// Path or URL; reduced by `route` before it is written.
        public var target: String?
        /// HTTP status; 0 if no response arrived.
        public var status: Int = 0
        /// Error type when the request failed without a response (e.g. `NSURLErrorDomain-1001`).
        public var failure: String?
        /// Telegram error code and text, e.g. 400 / CHANNEL_PRIVATE.
        public var tgCode: Int = 0
        public var tgError: String?
        public var durationMs: Int64 = -1
        /// `LuckgramProxyRoute` label.
        public var proxy: String?
        /// The server's `X-Request-Id` header.
        public var requestId: String?
        /// specs#81: host of the API entry used, and whether another entry failed first.
        public var endpoint: String?
        public var switched = false

        public init() {
        }
    }

    /// Reduces a path or URL to what identifies the endpoint: query and fragment dropped; for an
    /// absolute URL only host and path are kept (the host is left out for the API host).
    public static func route(_ target: String?, apiHost: String?) -> String {
        guard var s = target, !s.isEmpty else {
            return "-"
        }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            s = String(s[s.startIndex ..< cut])
        }
        if let scheme = s.range(of: "://") {
            var rest = String(s[scheme.upperBound...])
            let slash = rest.firstIndex(of: "/")
            if let at = rest.firstIndex(of: "@"), slash == nil || at < slash! {
                rest = String(rest[rest.index(after: at)...]) // never keep user:password@
            }
            let host: String
            let path: String
            if let slash = rest.firstIndex(of: "/") {
                host = String(rest[rest.startIndex ..< slash])
                path = String(rest[slash...])
            } else {
                host = rest
                path = "/"
            }
            if let apiHost, host.lowercased() == apiHost.lowercased() {
                s = path
            } else {
                s = host + path
            }
        }
        return clean(s, max: 160)
    }

    /// `<epoch ms> <UTC time> key=value ...`
    public static func format(_ e: Entry, apiHost: String?) -> String {
        var b = "\(e.timeMs) \(utc(e.timeMs))"
        field(&b, "feature", e.feature)
        b += " route=" + (e.method.map { clean($0, max: 8) + " " } ?? "") + route(e.target, apiHost: apiHost)
        if e.status > 0 {
            b += " status=\(e.status)"
        }
        field(&b, "exception", e.failure)
        if e.tgCode != 0 || e.tgError != nil {
            b += " tg=\(e.tgCode)"
            if let t = e.tgError {
                b += ":" + clean(t, max: maxField)
            }
        }
        if e.durationMs >= 0 {
            b += " ms=\(e.durationMs)"
        }
        field(&b, "proxy", e.proxy)
        field(&b, "rid", e.requestId)
        field(&b, "endpoint", e.endpoint)
        if e.switched {
            b += " switched=1"
        }
        return b
    }

    /// Keeps lines at most `maxAge` old that, newest first, fit in `maxBytes` (UTF-8, with
    /// newlines). Lines without a leading time are dropped. Order kept.
    public static func trim(_ lines: [String], nowMs: Int64, maxAge: TimeInterval, maxBytes: Int) -> [String] {
        var kept: [String] = []
        var bytes = 0
        let maxAgeMs = Int64(maxAge * 1000)
        for line in lines.reversed() {
            guard let t = timeOf(line), nowMs - t <= maxAgeMs else {
                continue
            }
            let size = line.utf8.count + 1
            if bytes + size > maxBytes {
                break
            }
            bytes += size
            kept.append(line)
        }
        return kept.reversed()
    }

    /// The epoch milliseconds a line starts with.
    public static func timeOf(_ line: String) -> Int64? {
        guard let sp = line.firstIndex(of: " "), sp != line.startIndex else {
            return nil
        }
        return Int64(line[line.startIndex ..< sp])
    }

    private static func field(_ b: inout String, _ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            b += " \(key)=" + clean(value, max: maxField)
        }
    }

    /// Only characters that can't carry free text across fields; capped.
    static func clean(_ s: String, max: Int) -> String {
        var out = ""
        for c in s.unicodeScalars {
            if out.unicodeScalars.count >= max {
                break
            }
            let v = c.value
            let ok = (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) || (v >= 0x30 && v <= 0x39) || "-_./:$".unicodeScalars.contains(c)
            out.unicodeScalars.append(ok ? c : "_")
        }
        return out
    }

    private static func utc(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}

/// Sorts a Telegram error returned before an AI request (e.g. loading history for a summary) so
/// the user sees the real reason instead of "network error".
public enum LuckgramTelegramErrorKind: Equatable {
    /// No answer from Telegram: a real network error.
    case network
    case noPermission
    /// FLOOD_WAIT_N: try again in N seconds.
    case floodWait
    /// The channel or group is private, or the user is no longer in it.
    case privateChat
    /// The topic, thread or message no longer exists.
    case notFound
    case other

    /// - Parameters:
    ///   - code: Telegram's error code (400, 403, 420, ...); 0 or negative means no answer
    ///   - text: Telegram's error text, e.g. `CHANNEL_PRIVATE`
    public static func of(code: Int, text: String?) -> LuckgramTelegramErrorKind {
        let t = text ?? ""
        if t.hasPrefix("FLOOD_WAIT_") || t.hasPrefix("FLOOD_PREMIUM_WAIT_") || t.hasPrefix("SLOWMODE_WAIT_") {
            return .floodWait
        }
        if code <= 0 || t.isEmpty {
            return .network
        }
        switch t {
        case "CHANNEL_PRIVATE", "CHANNEL_INVALID", "CHAT_INVALID", "PEER_ID_INVALID", "USER_NOT_PARTICIPANT":
            return .privateChat
        case "CHAT_ADMIN_REQUIRED", "CHAT_FORBIDDEN", "CHAT_RESTRICTED", "USER_BANNED_IN_CHANNEL", "CHAT_GUEST_SEND_FORBIDDEN":
            return .noPermission
        case "MSG_ID_INVALID", "TOPIC_ID_INVALID", "TOPIC_DELETED":
            return .notFound
        default:
            return code == 403 ? .noPermission : .other
        }
    }

    /// Seconds from FLOOD_WAIT_N-style texts; 0 if absent.
    public static func floodWaitSeconds(_ text: String?) -> Int {
        guard let text, let i = text.lastIndex(of: "_") else {
            return 0
        }
        return max(0, Int(text[text.index(after: i)...]) ?? 0)
    }
}
