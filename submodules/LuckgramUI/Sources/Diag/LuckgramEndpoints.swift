import Foundation

/// specs#81: the Luckgram API has several entries (same backend). Requests use the entry that
/// worked last; when an entry can't be reached (DNS, connect, TLS, reset, connect timeout) the same
/// request is sent again to the next one. An HTTP response of any status never switches. While a
/// backup is in use the first entry is probed every `probeInterval` (and once per cold start) and
/// taken back when it answers. Foundation only, unit tested on Linux; same rules as Android
/// `LuckgramEndpoints`.
public final class LuckgramEndpoints {
    public static let probeInterval: TimeInterval = 6 * 60 * 60
    public static let healthPath = "/v1/health"

    public let all: [String]
    private let lock = NSLock()
    private var currentIndex: Int
    /// nil = not probed since the process started, so the first check after a cold start probes.
    private var lastProbe: Date?

    /// - Parameters:
    ///   - bases: entries in order of preference (see `parse`); must not be empty
    ///   - remembered: the entry that worked last (persisted), or nil; ignored if not in the list
    public init(bases: [String], remembered: String?) {
        precondition(!bases.isEmpty, "no API entry")
        self.all = bases
        let wanted = remembered.flatMap(LuckgramEndpoints.normalize)?.lowercased()
        self.currentIndex = bases.firstIndex(where: { $0.lowercased() == wanted }) ?? 0
    }

    /// https entries without trailing slashes, duplicates dropped, order kept.
    public static func parse(_ list: [String]) -> [String] {
        var out: [String] = []
        for item in list {
            for part in item.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }) {
                if let b = normalize(String(part)), !out.contains(b) {
                    out.append(b)
                }
            }
        }
        return out
    }

    static func normalize(_ base: String) -> String? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") {
            b.removeLast()
        }
        guard b.lowercased().hasPrefix("https://"), b.count > "https://".count else {
            return nil
        }
        return b
    }

    public var primary: String {
        return self.all[0]
    }

    public var current: String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.all[self.currentIndex]
    }

    public var usingBackup: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.currentIndex != 0
    }

    /// The entries to try for one request: the current one first, then the others in list order.
    public func attemptOrder() -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        var out = [self.all[self.currentIndex]]
        for (i, b) in self.all.enumerated() where i != self.currentIndex {
            out.append(b)
        }
        return out
    }

    /// `base` answered: use it from now on. Returns true if the current entry changed.
    @discardableResult
    public func markWorking(_ base: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let i = self.all.firstIndex(where: { $0.lowercased() == base.lowercased() }), i != self.currentIndex else {
            return false
        }
        self.currentIndex = i
        return true
    }

    /// Whether the first entry should be probed now (only while a backup is in use). When true the
    /// probe is counted as started, so concurrent callers get false.
    public func takeProbe(now: Date) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.currentIndex != 0 else {
            return false
        }
        if let last = self.lastProbe, now >= last, now.timeIntervalSince(last) < LuckgramEndpoints.probeInterval {
            return false
        }
        self.lastProbe = now
        return true
    }

    /// The entry `url` starts with (scheme and host compared without case), or nil.
    public func base(of url: String) -> String? {
        let lower = url.lowercased()
        for b in self.all {
            let lb = b.lowercased()
            guard lower.hasPrefix(lb) else {
                continue
            }
            let rest = lower.dropFirst(lb.count)
            if rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("?") || rest.hasPrefix("#") {
                return b
            }
        }
        return nil
    }

    /// Whether `host` is the host of one of the entries.
    public func isEntryHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        return self.all.contains(where: { LuckgramEndpoints.host(of: $0) == host })
    }

    /// A URL returned by the server (images, avatars, videos) that points at another entry is moved
    /// to the current one; other URLs are returned unchanged.
    public func rewrite(_ url: String) -> String {
        guard let b = self.base(of: url) else {
            return url
        }
        let cur = self.current
        if b == cur {
            return url
        }
        return cur + String(url.dropFirst(b.count))
    }

    public static func host(of base: String) -> String {
        var rest = Substring(base)
        if let r = base.range(of: "://") {
            rest = base[r.upperBound...]
        }
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == ":" || $0 == "?" || $0 == "#" }) {
            rest = rest[..<end]
        }
        return rest.lowercased()
    }

    /// Whether a request that got no HTTP response may go to the next entry: the entry couldn't be
    /// reached (DNS, connect, TLS, reset, timeout) and, for a request with a body, nothing of the
    /// body was sent yet (so a request the server may have got is never sent twice).
    /// - Parameters:
    ///   - domain: `NSURLErrorDomain` for URLSession errors
    ///   - bodyBytesSent: `countOfBytesSent` of the failed task
    public static func shouldSwitch(domain: String, code: Int, hasBody: Bool, bodyBytesSent: Int64) -> Bool {
        // NSURLError codes as numbers: the constants are not in plain Foundation on Linux (tests).
        guard domain == "NSURLErrorDomain" else {
            return false
        }
        switch code {
        case -1003, -1006, -1004, -1200, -1201, -1202, -1203, -1204, -1205:
            // cannot find host, DNS lookup failed, cannot connect, TLS failed, certificate errors:
            // the connection never got far enough for the request to be sent
            return true
        case -1005, -1001:
            // connection lost, timed out: only if nothing of the body went out
            return !hasBody || bodyBytesSent == 0
        default:
            return false
        }
    }
}
