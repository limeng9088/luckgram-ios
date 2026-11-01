import Foundation

/// Mock of the "Discover" endpoints (S10 nearby, S11 square) for `LuckgramAIMock`, so the pages run
/// end to end before the server is live. Same paths, bodies and error format as agreed with
/// S10/S11; state in memory only. Same behaviour as Android's `DiscoverMock`.
public final class DiscoverMock {
    public struct Reply {
        public let status: Int
        public let body: [String: Any]
    }

    private let lock = NSLock()
    private var linked = true
    private var myCard: [String: Any]?
    private var myExpiresAt: Date?
    private var blocked = Set<String>()
    private var people: [[String: Any]] = []
    private var nearbyUpdates = 0
    private var nearbyQueries = 0

    public init() {
        let seed: [(String, String, String, String)] = [
            ("m1", "Alice", "喜欢咖啡和徒步", "500m"),
            ("m2", "Bob", "iOS developer", "500m"),
            ("m3", "小林", "周末一起打球", "1km"),
            ("m4", "Carol", "", "1km"),
            ("m5", "Dave", "Photographer", "3km"),
            ("m6", "王五", "新搬来的邻居", "10km"),
            ("m7", "Eve", "Hi!", "far")
        ]
        for s in seed {
            self.people.append(["id": s.0, "display_name": s.1, "bio": s.2, "username": "mock_\(s.0)", "distance_bucket": s.3])
        }
    }

    public func setLinked(_ value: Bool) {
        self.lock.lock()
        self.linked = value
        self.lock.unlock()
    }

    public var lastCard: [String: Any]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.myCard
    }

    /// nil when the path is not a discover endpoint.
    public func handle(method: String, path: String, query: String?, body: Data) -> Reply? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let query = query ?? ""
        if path == "/v1/link" {
            if method == "DELETE" {
                self.linked = false
                self.myCard = nil
                self.myExpiresAt = nil
                return Reply(status: 200, body: [:])
            }
            return Reply(status: 200, body: ["linked": self.linked, "devices": self.linked ? 1 : 0, "max_devices": 3])
        }
        if path == "/v1/blocks" {
            if method == "POST" {
                if !self.linked {
                    return DiscoverMock.error(403, "not_linked")
                }
                let user = DiscoverMock.json(body)["user"] as? String ?? ""
                if user.isEmpty {
                    return DiscoverMock.error(400, "invalid_request")
                }
                self.blocked.insert(user)
                return Reply(status: 200, body: [:])
            }
            if !self.linked {
                return DiscoverMock.error(403, "not_linked")
            }
            return Reply(status: 200, body: ["items": self.blocked.map { ["user": $0] }])
        }
        if path.hasPrefix("/v1/blocks/") && method == "DELETE" {
            if !self.linked {
                return DiscoverMock.error(403, "not_linked")
            }
            self.blocked.remove(String(path.dropFirst("/v1/blocks/".count)))
            return Reply(status: 200, body: [:])
        }
        if path == "/v1/nearby" || path.hasPrefix("/v1/nearby/") {
            return self.nearby(method: method, path: path, query: query, body: body)
        }
        return nil
    }

    private func nearby(method: String, path: String, query: String, body: Data) -> Reply {
        if !self.linked {
            return DiscoverMock.error(403, "not_linked")
        }
        switch path {
        case "/v1/nearby/me":
            if method == "PUT" {
                let card = DiscoverMock.json(body)
                guard let lat = card["lat"], let lon = card["lon"], !(card["username"] as? String ?? "").isEmpty else {
                    return DiscoverMock.error(400, "invalid_request")
                }
                if DiscoverMock.decimals("\(lat)") > 2 || DiscoverMock.decimals("\(lon)") > 2 {
                    return DiscoverMock.error(400, "invalid_request")
                }
                self.nearbyUpdates += 1
                if self.nearbyUpdates > 6 {
                    return DiscoverMock.rateLimited(600)
                }
                self.myCard = card
                let expires = Date().addingTimeInterval(24 * 3600)
                self.myExpiresAt = expires
                return Reply(status: 200, body: ["visible": true, "expires_at": DiscoverMock.iso(expires)])
            } else if method == "DELETE" {
                self.myCard = nil
                self.myExpiresAt = nil
                return Reply(status: 200, body: [:])
            } else {
                if self.myCard != nil, let e = self.myExpiresAt, Date() < e {
                    return Reply(status: 200, body: ["visible": true, "expires_at": DiscoverMock.iso(e)])
                }
                return Reply(status: 200, body: ["visible": false])
            }
        case "/v1/nearby":
            if !query.contains("lat=") || !query.contains("lon=") {
                return DiscoverMock.error(400, "invalid_request")
            }
            self.nearbyQueries += 1
            if self.nearbyQueries > 30 {
                return DiscoverMock.rateLimited(1200)
            }
            let list = self.people.filter { !self.blocked.contains($0["id"] as? String ?? "") }.shuffled()
            return Reply(status: 200, body: ["items": list])
        case "/v1/nearby/report":
            let r = DiscoverMock.json(body)
            if (r["user"] as? String ?? "").isEmpty || (r["reason"] as? String ?? "").isEmpty {
                return DiscoverMock.error(400, "invalid_request")
            }
            return Reply(status: 200, body: [:])
        default:
            return DiscoverMock.error(404, "not_found")
        }
    }

    public func resetLimits() {
        self.lock.lock()
        self.nearbyUpdates = 0
        self.nearbyQueries = 0
        self.lock.unlock()
    }

    // MARK: - helpers

    static func decimals(_ number: String) -> Int {
        guard let dot = number.firstIndex(of: ".") else {
            return 0
        }
        let frac = number[number.index(after: dot)...]
        if frac.lowercased().contains("e") {
            return 99
        }
        return frac.count
    }

    static func json(_ body: Data) -> [String: Any] {
        if body.isEmpty {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func error(_ status: Int, _ code: String) -> Reply {
        return Reply(status: status, body: ["error": ["code": code, "message": code]])
    }

    static func rateLimited(_ seconds: Int) -> Reply {
        return Reply(status: 429, body: ["error": ["code": "rate_limited", "message": "rate_limited", "retry_after_seconds": seconds]])
    }
}
