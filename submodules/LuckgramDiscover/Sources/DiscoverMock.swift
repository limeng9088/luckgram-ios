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

    // square (26 / S11)
    /// Host of the in-app mock (LuckgramAIMock.host); kept here so this module stays Foundation-only.
    public static let mockHost = "luckgram-mock.invalid"
    public static let myId = "me"
    public static let uploadPrefix = "/mock-upload/"
    public static let imagePrefix = "/mock-image/"
    /// Reports per target id; at `reportHideThreshold` the content is hidden (S11: 3 different users; the mock has one).
    public static let reportHideThreshold = 3
    private var reports: [String: Int] = [:]
    private var squareProfile: [String: Any]?
    private var posts: [[String: Any]] = []
    private var comments: [[String: Any]] = []
    private var myLikes = Set<String>()
    private var uploaded = Set<String>()
    private var myPostTimes: [Date] = []
    private var myCommentTimes: [Date] = []
    private var nextId = 100

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
        let now = Date()
        for i in 0 ..< 25 {
            let who = seed[i % seed.count]
            let author: [String: Any] = ["id": who.0, "display_name": who.1, "username": "mock_\(who.0)", "bio": who.2]
            var images: [[String: Any]] = []
            for k in 0 ..< (i % 4) {
                images.append(["url": "https://\(DiscoverMock.mockHost)\(DiscoverMock.imagePrefix)\(i)_\(k).png", "width": 1, "height": 1])
            }
            self.posts.append([
                "id": "p\(i)", "author": author,
                "text": (i % 2 == 0 ? "Mock 帖子 #" : "Mock post #") + "\(i)",
                "images": images, "like_count": (i * 7) % 13, "comment_count": 0,
                "created_at_ms": now.timeIntervalSince1970 * 1000 - Double(i) * 3_600_000, "status": "published"
            ])
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
        if path.hasPrefix("/v1/square/") {
            return self.square(method: method, path: path, query: query, body: body)
        }
        return nil
    }

    /// Presigned upload (no auth header, like S3). True when the key was issued by this mock.
    public func acceptUpload(path: String, body: Data) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard path.hasPrefix(DiscoverMock.uploadPrefix), !body.isEmpty else {
            return false
        }
        let key = String(path.dropFirst(DiscoverMock.uploadPrefix.count))
        guard key.hasPrefix("square/") else {
            return false
        }
        self.uploaded.insert(key)
        return true
    }

    public func isUploaded(_ key: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.uploaded.contains(key)
    }

    // MARK: - square

    private static func param(_ query: String, _ name: String) -> String? {
        for kv in query.split(separator: "&") {
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 && parts[0] == name {
                return parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return nil
    }

    private func myAuthor() -> [String: Any] {
        let p = self.squareProfile ?? [:]
        var a: [String: Any] = ["id": DiscoverMock.myId, "display_name": p["display_name"] as? String ?? "Me", "bio": p["bio"] as? String ?? ""]
        if let u = p["username"] as? String, !u.isEmpty {
            a["username"] = u
        }
        return a
    }

    private func postIndex(_ id: String) -> Int? {
        return self.posts.firstIndex(where: { ($0["id"] as? String) == id })
    }

    private static func isMine(_ o: [String: Any]) -> Bool {
        return ((o["author"] as? [String: Any])?["id"] as? String) == DiscoverMock.myId
    }

    private func visible(_ o: [String: Any]) -> Bool {
        if let a = (o["author"] as? [String: Any])?["id"] as? String, self.blocked.contains(a) {
            return false
        }
        return DiscoverMock.isMine(o) || (o["status"] as? String) == "published"
    }

    private static func createdMs(_ o: [String: Any]) -> Double {
        return (o["created_at_ms"] as? NSNumber)?.doubleValue ?? 0
    }

    private func countReport(target: String, id: String) {
        let n = (self.reports[id] ?? 0) + 1
        self.reports[id] = n
        if n < DiscoverMock.reportHideThreshold {
            return
        }
        if target == "comment" {
            for i in self.comments.indices where (self.comments[i]["id"] as? String) == id {
                self.comments[i]["status"] = "hidden"
                self.comments[i]["hidden_reason"] = "Mock: 被多名用户举报 / reported by several users"
            }
        } else {
            for i in self.posts.indices where (self.posts[i]["id"] as? String) == id {
                self.posts[i]["status"] = "hidden"
                self.posts[i]["hidden_reason"] = "Mock: 被多名用户举报 / reported by several users"
            }
        }
    }

    private func out(_ p: [String: Any]) -> [String: Any] {
        var o = p
        o.removeValue(forKey: "created_at_ms")
        o["created_at"] = DiscoverMock.iso(Date(timeIntervalSince1970: DiscoverMock.createdMs(p) / 1000))
        let id = p["id"] as? String ?? ""
        o["liked"] = self.linked && self.myLikes.contains(id)
        o["comment_count"] = self.comments.filter { ($0["post_id"] as? String) == id && self.visible($0) }.count
        if !DiscoverMock.isMine(p) {
            o.removeValue(forKey: "hidden_reason")
        }
        return o
    }

    private func page(_ list: [[String: Any]], cursor: String?) -> Reply {
        let from = cursor.flatMap { Int($0) } ?? 0
        let to = min(list.count, from + 20)
        var body: [String: Any] = ["items": from < to ? list[from ..< to].map { self.out($0) } : []]
        if to < list.count {
            body["next_cursor"] = "\(to)"
        }
        return Reply(status: 200, body: body)
    }

    private func limited(_ times: inout [Date], window: TimeInterval, max: Int) -> Reply? {
        let now = Date()
        times.removeAll(where: { now.timeIntervalSince($0) >= window })
        if times.count >= max, let first = times.first {
            return DiscoverMock.rateLimited(Swift.max(1, Int((window - now.timeIntervalSince(first)).rounded(.up))))
        }
        times.append(now)
        return nil
    }

    private func hot(_ p: [String: Any]) -> Double {
        let id = p["id"] as? String ?? ""
        let c = self.comments.filter { ($0["post_id"] as? String) == id }.count
        let ageH = (Date().timeIntervalSince1970 * 1000 - DiscoverMock.createdMs(p)) / 3_600_000
        return (Double((p["like_count"] as? NSNumber)?.intValue ?? 0) + 2 * Double(c)) * pow(0.5, ageH / 24)
    }

    private func square(method: String, path: String, query: String, body: Data) -> Reply {
        let write = method != "GET"
        if write && !self.linked {
            return DiscoverMock.error(403, "not_linked")
        }
        if path == "/v1/square/feed" {
            var list = self.posts.filter { self.visible($0) }
            if DiscoverMock.param(query, "tab") == "hot" {
                list.sort { self.hot($0) > self.hot($1) }
            } else {
                list.sort { DiscoverMock.createdMs($0) > DiscoverMock.createdMs($1) }
            }
            return self.page(list, cursor: DiscoverMock.param(query, "cursor"))
        }
        if path == "/v1/square/profile" {
            if method == "PUT" {
                let p = DiscoverMock.json(body)
                if (p["display_name"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    return DiscoverMock.error(400, "invalid_request")
                }
                self.squareProfile = p
                var r = p
                r["id"] = DiscoverMock.myId
                return Reply(status: 200, body: r)
            }
            if !self.linked {
                return DiscoverMock.error(403, "not_linked")
            }
            guard var p = self.squareProfile else {
                return DiscoverMock.error(404, "not_found")
            }
            p["id"] = DiscoverMock.myId
            return Reply(status: 200, body: p)
        }
        if path == "/v1/square/me" && method == "DELETE" {
            self.posts.removeAll(where: { DiscoverMock.isMine($0) })
            self.comments.removeAll(where: { DiscoverMock.isMine($0) || self.postIndex($0["post_id"] as? String ?? "") == nil })
            for id in self.myLikes {
                if let i = self.postIndex(id) {
                    self.posts[i]["like_count"] = max(0, ((self.posts[i]["like_count"] as? NSNumber)?.intValue ?? 0) - 1)
                }
            }
            self.myLikes.removeAll()
            self.squareProfile = nil
            return Reply(status: 200, body: [:])
        }
        if path == "/v1/square/uploads" && method == "POST" {
            let r = DiscoverMock.json(body)
            let count = (r["count"] as? NSNumber)?.intValue ?? 0
            let ct = r["content_type"] as? String ?? ""
            let video = ct == "video/mp4"
            if count < 1 || count > 9 || !(ct == "image/jpeg" || video) {
                return DiscoverMock.error(400, "invalid_request")
            }
            var ups: [[String: Any]] = []
            for _ in 0 ..< count {
                let key = "square/mock_\(self.nextId)" + (video ? ".mp4" : ".jpg")
                self.nextId += 1
                ups.append(["key": key, "url": "https://\(DiscoverMock.mockHost)\(DiscoverMock.uploadPrefix)\(key)", "expires_at": DiscoverMock.iso(Date().addingTimeInterval(900))])
            }
            return Reply(status: 200, body: ["uploads": ups])
        }
        if path == "/v1/square/posts" && method == "POST" {
            if self.squareProfile == nil {
                return DiscoverMock.error(403, "profile_required")
            }
            let r = DiscoverMock.json(body)
            let text = r["text"] as? String ?? ""
            let keys = r["image_keys"] as? [String] ?? []
            if text.unicodeScalars.count > 1000 || keys.count > 9 || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keys.isEmpty) {
                return DiscoverMock.error(400, "invalid_request")
            }
            var images: [[String: Any]] = []
            for k in keys {
                if !self.uploaded.contains(k) {
                    return DiscoverMock.error(400, "invalid_request")
                }
                images.append(["url": "https://\(DiscoverMock.mockHost)\(DiscoverMock.imagePrefix)\(k)", "width": 1, "height": 1])
            }
            var video: [String: Any]?
            let vk = r["video_key"] as? String ?? ""
            let ck = r["cover_key"] as? String ?? ""
            if !vk.isEmpty || !ck.isEmpty {
                if !keys.isEmpty {
                    return DiscoverMock.error(400, "invalid_request") // attachments are exclusive
                }
                if !self.uploaded.contains(vk) || !self.uploaded.contains(ck) || !vk.hasSuffix(".mp4") {
                    return DiscoverMock.error(400, "invalid_video")
                }
                // The real server reads these from the file; the mock has no decoder.
                video = ["url": "https://\(DiscoverMock.mockHost)/mock-video/\(vk)", "cover_url": "https://\(DiscoverMock.mockHost)\(DiscoverMock.imagePrefix)\(ck)",
                         "width": 1280, "height": 720, "duration_seconds": 15, "size": 1]
            }
            if let lim = self.limited(&self.myPostTimes, window: 24 * 3600, max: 10) {
                return lim
            }
            var p: [String: Any] = ["id": "p\(self.nextId)", "author": self.myAuthor(), "text": text, "images": images,
                                    "like_count": 0, "comment_count": 0, "created_at_ms": Date().timeIntervalSince1970 * 1000, "status": "published"]
            if let video {
                p["video"] = video
            }
            self.nextId += 1
            self.posts.insert(p, at: 0)
            return Reply(status: 200, body: self.out(p))
        }
        if path.hasPrefix("/v1/square/posts/") {
            let rest = String(path.dropFirst("/v1/square/posts/".count))
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            let id = parts.first ?? ""
            let sub = parts.count > 1 ? parts[1] : ""
            guard let index = self.postIndex(id), self.visible(self.posts[index]) else {
                return DiscoverMock.error(404, "not_found")
            }
            switch sub {
            case "":
                if method == "DELETE" {
                    if !DiscoverMock.isMine(self.posts[index]) {
                        return DiscoverMock.error(403, "forbidden")
                    }
                    self.posts.remove(at: index)
                    return Reply(status: 200, body: [:])
                }
                return Reply(status: 200, body: self.out(self.posts[index]))
            case "like":
                var count = (self.posts[index]["like_count"] as? NSNumber)?.intValue ?? 0
                if method == "POST" {
                    if self.myLikes.insert(id).inserted {
                        count += 1
                    }
                } else if self.myLikes.remove(id) != nil {
                    count = max(0, count - 1)
                }
                self.posts[index]["like_count"] = count
                return Reply(status: 200, body: ["like_count": count, "liked": self.myLikes.contains(id)])
            case "comments":
                if method == "POST" {
                    if self.squareProfile == nil {
                        return DiscoverMock.error(403, "profile_required")
                    }
                    let r = DiscoverMock.json(body)
                    let text = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty || text.unicodeScalars.count > 300 {
                        return DiscoverMock.error(400, "invalid_request")
                    }
                    if let lim = self.limited(&self.myCommentTimes, window: 60, max: 5) {
                        return lim
                    }
                    var c: [String: Any] = ["id": "c\(self.nextId)", "post_id": id, "author": self.myAuthor(), "text": text,
                                            "created_at": DiscoverMock.iso(Date()), "status": "published"]
                    self.nextId += 1
                    if let parent = r["parent_id"] as? String, !parent.isEmpty {
                        c["parent_id"] = parent
                    }
                    self.comments.append(c)
                    return Reply(status: 200, body: c)
                }
                return Reply(status: 200, body: ["items": self.comments.filter { ($0["post_id"] as? String) == id && self.visible($0) }])
            default:
                return DiscoverMock.error(404, "not_found")
            }
        }
        if path.hasPrefix("/v1/square/comments/") && method == "DELETE" {
            let id = String(path.dropFirst("/v1/square/comments/".count))
            guard let i = self.comments.firstIndex(where: { ($0["id"] as? String) == id }) else {
                return DiscoverMock.error(404, "not_found")
            }
            let c = self.comments[i]
            let post = self.postIndex(c["post_id"] as? String ?? "").map { self.posts[$0] }
            if !DiscoverMock.isMine(c) && !(post.map { DiscoverMock.isMine($0) } ?? false) {
                return DiscoverMock.error(403, "forbidden")
            }
            self.comments.remove(at: i)
            return Reply(status: 200, body: [:])
        }
        if path.hasPrefix("/v1/square/users/") {
            let rest = String(path.dropFirst("/v1/square/users/".count))
            let postsOnly = rest.hasSuffix("/posts")
            let user = postsOnly ? String(rest.dropLast("/posts".count)) : rest
            if self.blocked.contains(user) {
                return DiscoverMock.error(404, "not_found")
            }
            var author: [String: Any]?
            var list: [[String: Any]] = []
            for p in self.posts {
                if let a = p["author"] as? [String: Any], (a["id"] as? String) == user {
                    if author == nil {
                        author = a
                    }
                    if self.visible(p) {
                        list.append(p)
                    }
                }
            }
            if user == DiscoverMock.myId {
                author = self.myAuthor()
            }
            guard let found = author else {
                return DiscoverMock.error(404, "not_found")
            }
            if postsOnly {
                return self.page(list, cursor: DiscoverMock.param(query, "cursor"))
            }
            return Reply(status: 200, body: ["author": found])
        }
        if path == "/v1/square/report" && method == "POST" {
            let r = DiscoverMock.json(body)
            if (r["target"] as? String ?? "").isEmpty || (r["id"] as? String ?? "").isEmpty || (r["reason"] as? String ?? "").isEmpty {
                return DiscoverMock.error(400, "invalid_request")
            }
            self.countReport(target: r["target"] as? String ?? "", id: r["id"] as? String ?? "")
            return Reply(status: 200, body: [:])
        }
        return DiscoverMock.error(404, "not_found")
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

    /// Decimal places of a coordinate as sent; exponent notation ("1e-05") counts as too precise.
    static func decimals(_ number: String) -> Int {
        if number.lowercased().contains("e") {
            return 99
        }
        guard let dot = number.firstIndex(of: ".") else {
            return 0
        }
        return number[number.index(after: dot)...].count
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
