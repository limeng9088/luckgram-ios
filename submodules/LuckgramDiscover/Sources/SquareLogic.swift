import Foundation

/// Pure logic of "Square" (spec 26, server S11): response parsing, limits, image and video sizing,
/// comment threading, permissions, the silent S6 link and all texts in both languages. Foundation
/// only (SwiftPM tests on Linux); the same rules are in `org.telegram.luckgram.square.SquareLogic`.
public enum SquareLogic {
    public static let featureKey = "square"

    public static let textMax = 1000
    public static let commentMax = 300
    public static let imagesMax = 9
    public static let pageSize = 20
    /// Long edge after client-side compression (spec 26 item 3).
    public static let imageMaxEdge = 2048
    public static let profileBioMax = 70
    /// Built-in default for `square.max_posts_per_day`; the remote config value wins (spec 26 item 7).
    public static let defaultMaxPostsPerDay = 10
    /// Built-in default for `square.max_video_seconds`; the remote config value wins (spec 26 item 3).
    public static let defaultMaxVideoSeconds = 60
    /// Short video after client-side transcoding: long edge ≤ 1280 px, H.264/AAC MP4, ≤ `square.max_video_mb` (default 50).
    public static let videoMaxEdge = 1280
    public static let defaultMaxVideoMb = 50
    public static let videoMaxBytes = defaultMaxVideoMb * 1024 * 1024
    public static let imageContentType = "image/jpeg"
    public static let videoContentType = "video/mp4"

    public static let tabLatest = "latest"
    public static let tabHot = "hot"
    /// specs#115: personalized feed (server ranks by the user's behavior).
    public static let tabRecommend = "recommend"

    /// Posts are public as soon as they are created; reported ones are hidden (S11 governance).
    public static let statusPublished = "published"
    public static let statusHidden = "hidden"

    // MARK: - model

    public struct Author: Equatable {
        public var id: String = ""
        public var displayName: String = ""
        public var avatarUrl: String?
        public var username: String?
        public var bio: String = ""

        public init(id: String = "", displayName: String = "", avatarUrl: String? = nil, username: String? = nil, bio: String = "") {
            self.id = id
            self.displayName = displayName
            self.avatarUrl = avatarUrl
            self.username = username
            self.bio = bio
        }
    }

    public struct Image: Equatable {
        public var url: String
        public var width: Int
        public var height: Int

        public init(url: String, width: Int = 0, height: Int = 0) {
            self.url = url
            self.width = width
            self.height = height
        }
    }

    /// One short video: the MP4, its cover frame and the duration in seconds.
    public struct Video: Equatable {
        public var url: String
        public var coverUrl: String?
        public var width: Int
        public var height: Int
        public var durationSeconds: Int

        public init(url: String, coverUrl: String? = nil, width: Int = 0, height: Int = 0, durationSeconds: Int = 0) {
            self.url = url
            self.coverUrl = coverUrl
            self.width = width
            self.height = height
            self.durationSeconds = durationSeconds
        }
    }

    public struct Post: Equatable {
        public var id: String = ""
        public var author = Author()
        public var text: String = ""
        public var images: [Image] = []
        public var video: Video?
        public var likeCount: Int = 0
        public var commentCount: Int = 0
        public var liked: Bool = false
        public var createdAt: Date?
        public var status: String = SquareLogic.statusPublished
        /// Why the post was hidden (only sent to its author).
        public var hiddenReason: String?

        public var isHidden: Bool {
            return self.status == SquareLogic.statusHidden
        }

        public init() {
        }
    }

    public struct Comment: Equatable {
        public var id: String = ""
        public var postId: String = ""
        public var parentId: String?
        public var author = Author()
        public var text: String = ""
        public var createdAt: Date?
        public var status: String = SquareLogic.statusPublished
        public var hiddenReason: String?
        /// Set by `thread`: 0 = comment, 1 = reply.
        public var depth: Int = 0

        public init(id: String = "", postId: String = "", parentId: String? = nil, author: Author = Author(), text: String = "") {
            self.id = id
            self.postId = postId
            self.parentId = parentId
            self.author = author
            self.text = text
        }
    }

    public struct Page<T> {
        public var items: [T] = []
        public var nextCursor: String?
    }

    public struct Upload: Equatable {
        public var key: String
        public var url: String
    }

    // MARK: - parsing

    private static func str(_ o: [String: Any], _ key: String) -> String? {
        guard let v = o[key] as? String, !v.isEmpty else {
            return nil
        }
        return v
    }

    private static func int(_ o: [String: Any], _ key: String) -> Int {
        if let n = o[key] as? NSNumber {
            return n.intValue
        }
        if let s = o[key] as? String, let n = Int(s) {
            return n
        }
        return 0
    }

    private static func bool(_ o: [String: Any], _ key: String) -> Bool {
        if let b = o[key] as? Bool {
            return b
        }
        if let n = o[key] as? NSNumber {
            return n.boolValue
        }
        return false
    }

    static func httpsOrNil(_ url: String?) -> String? {
        guard let url, url.hasPrefix("https://") else {
            return nil
        }
        return url
    }

    public static func parseAuthor(_ o: [String: Any]?) -> Author {
        guard let o else {
            return Author()
        }
        var a = Author()
        a.id = o["id"] as? String ?? ""
        a.displayName = o["display_name"] as? String ?? ""
        a.avatarUrl = httpsOrNil(str(o, "avatar_url"))
        a.username = str(o, "username")
        a.bio = o["bio"] as? String ?? ""
        return a
    }

    public static func parseVideo(_ o: [String: Any]?) -> Video? {
        guard let o, let url = httpsOrNil(str(o, "url")) else {
            return nil
        }
        return Video(url: url, coverUrl: httpsOrNil(str(o, "cover_url")), width: max(0, int(o, "width")), height: max(0, int(o, "height")), durationSeconds: max(0, int(o, "duration_seconds")))
    }

    public static func parsePost(_ o: [String: Any]) -> Post {
        var p = Post()
        p.id = o["id"] as? String ?? ""
        p.author = parseAuthor(o["author"] as? [String: Any])
        p.text = o["text"] as? String ?? ""
        for io in (o["images"] as? [[String: Any]]) ?? [] {
            guard p.images.count < imagesMax, let url = httpsOrNil(str(io, "url")) else {
                continue
            }
            p.images.append(Image(url: url, width: int(io, "width"), height: int(io, "height")))
        }
        p.video = parseVideo(o["video"] as? [String: Any])
        if p.video != nil {
            p.images = [] // attachments are exclusive
        }
        p.likeCount = max(0, int(o, "like_count"))
        p.commentCount = max(0, int(o, "comment_count"))
        p.liked = bool(o, "liked")
        p.createdAt = parseTime(o["created_at"] as? String)
        p.status = normalizeStatus(o["status"] as? String)
        p.hiddenReason = hiddenReason(o)
        return p
    }

    public static func parseComment(_ o: [String: Any]) -> Comment {
        var c = Comment()
        c.id = o["id"] as? String ?? ""
        c.postId = o["post_id"] as? String ?? ""
        c.parentId = str(o, "parent_id")
        c.author = parseAuthor(o["author"] as? [String: Any])
        c.text = o["text"] as? String ?? ""
        c.createdAt = parseTime(o["created_at"] as? String)
        c.status = normalizeStatus(o["status"] as? String)
        c.hiddenReason = hiddenReason(o)
        return c
    }

    public static func parsePosts(_ j: [String: Any]) -> Page<Post> {
        var page = Page<Post>()
        for o in (j["items"] as? [[String: Any]]) ?? [] {
            let p = parsePost(o)
            if !p.id.isEmpty {
                page.items.append(p)
            }
        }
        page.nextCursor = str(j, "next_cursor")
        return page
    }

    public static func parseComments(_ j: [String: Any]) -> Page<Comment> {
        var page = Page<Comment>()
        for o in (j["items"] as? [[String: Any]]) ?? [] {
            let c = parseComment(o)
            if !c.id.isEmpty {
                page.items.append(c)
            }
        }
        page.nextCursor = str(j, "next_cursor")
        return page
    }

    /// `{"uploads":[{"key","url"}]}`; entries without an https URL are dropped.
    public static func parseUploads(_ j: [String: Any]?) -> [Upload] {
        var out: [Upload] = []
        for o in (j?["uploads"] as? [[String: Any]]) ?? [] {
            guard let key = o["key"] as? String, !key.isEmpty, let url = httpsOrNil(str(o, "url")) else {
                continue
            }
            out.append(Upload(key: key, url: url))
        }
        return out
    }

    /// Anything but `hidden` is shown as published.
    static func normalizeStatus(_ s: String?) -> String {
        return s == statusHidden ? statusHidden : statusPublished
    }

    static func hiddenReason(_ o: [String: Any]) -> String? {
        return str(o, "hidden_reason") ?? str(o, "reason")
    }

    /// Appends a page without duplicates (cursor pages may overlap after new posts).
    public static func appendUnique(_ into: inout [Post], _ page: [Post]) {
        for p in page where !into.contains(where: { $0.id == p.id }) {
            into.append(p)
        }
    }

    // MARK: - saved first page

    /// A saved first page older than this is not shown any more.
    public static let savedMaxAgeMs: Int64 = 7 * 24 * 3600_000

    /// A first page as it was saved, and when.
    public struct Saved {
        public let page: Page<Post>
        public let savedAtMs: Int64
    }

    /// What is kept on the device for a tab: the server's first page as it came, and the time.
    public static func encodeSaved(_ firstPage: [String: Any], now: Int64) -> String? {
        let o: [String: Any] = ["saved_at": NSNumber(value: now), "page": firstPage]
        guard JSONSerialization.isValidJSONObject(o), let data = try? JSONSerialization.data(withJSONObject: o) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Nil when there is nothing usable: unreadable, empty, too old, or from the future.
    public static func decodeSaved(_ stored: String?, now: Int64) -> Saved? {
        guard let stored, let data = stored.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard let savedAt = (o["saved_at"] as? NSNumber)?.int64Value, let page = o["page"] as? [String: Any] else {
            return nil
        }
        if savedAt <= 0 || savedAt > now || now - savedAt > savedMaxAgeMs {
            return nil
        }
        let parsed = parsePosts(page)
        return parsed.items.isEmpty ? nil : Saved(page: parsed, savedAtMs: savedAt)
    }

    // MARK: - feed state

    /// One tab of the feed, kept for as long as the page is open. A refresh never empties the list:
    /// the posts on screen stay until the new first page has arrived and then are swapped in one
    /// step; a failed refresh leaves them untouched. Tabs keep their own list and position, so
    /// switching back shows what was there, and reloads only when it is older than `staleMs`.
    /// The same class lives in SquareLogic.java.
    public final class Feed {
        /// A tab shown again after this long refreshes itself.
        public static let staleMs: Int64 = 5 * 60_000
        /// The next page is requested when this many posts are left below the last visible one.
        public static let prefetch = 4
        /// A page that has not come after this long counts as failed (the list stays, the reader is told).
        public static let requestTimeoutMs: Int64 = 15_000

        public enum Footer: Equatable {
            case skeleton
            case firstError
            case empty
            case loadingMore
            case moreError
            case end
        }

        public let tab: String
        public var posts: [Post] = []
        public var nextCursor: String?
        public var loadedOnce = false
        public var loadedAtMs: Int64 = 0
        /// When the reader last had this tab on screen (`markSeen`).
        public var seenAtMs: Int64 = 0
        public var refreshing = false
        public var refreshFailed = false
        public var loadingMore = false
        public var moreFailed = false
        /// Bumped by every applied refresh: a page requested for the previous list is dropped.
        public var generation = 0
        /// First visible post, saved when the tab is left.
        public var scrollIndex = 0

        public init(tab: String) {
            self.tab = tab
        }

        /// False when a refresh is already running.
        public func beginRefresh() -> Bool {
            if self.refreshing {
                return false
            }
            self.refreshing = true
            self.refreshFailed = false
            return true
        }

        /// The first page arrived: it replaces the list in one step. Returns how many of its posts
        /// were not in the list before (0 on the very first load).
        @discardableResult
        public func applyRefresh(_ page: Page<Post>, now: Int64) -> Int {
            var fresh = 0
            if self.loadedOnce {
                let old = Set(self.posts.map { $0.id })
                fresh = page.items.filter { !old.contains($0.id) }.count
            }
            self.posts = []
            SquareLogic.appendUnique(&self.posts, page.items)
            self.nextCursor = page.nextCursor
            self.loadedOnce = true
            self.loadedAtMs = now
            self.refreshing = false
            self.refreshFailed = false
            self.loadingMore = false
            self.moreFailed = false
            self.generation += 1
            self.scrollIndex = 0
            return fresh
        }

        /// The first page saved by an earlier visit (`decodeSaved`): shown at once when the page
        /// opens, before anything is requested. It counts as loaded at the time it was saved, so
        /// an old one is refreshed right away — with the posts on screen meanwhile. False when
        /// the tab already has a list.
        @discardableResult
        public func restore(_ page: Page<Post>, savedAtMs: Int64) -> Bool {
            if self.loadedOnce || page.items.isEmpty {
                return false
            }
            SquareLogic.appendUnique(&self.posts, page.items)
            self.nextCursor = page.nextCursor
            self.loadedOnce = true
            self.loadedAtMs = savedAtMs
            return true
        }

        /// The page that was loading is gone (its requests were cancelled): nothing is in flight.
        public func cancelLoading() {
            self.refreshing = false
            self.loadingMore = false
        }

        /// The refresh failed: whatever was on screen stays.
        public func failRefresh() {
            self.refreshing = false
            self.refreshFailed = true
        }

        public var canLoadMore: Bool {
            return self.loadedOnce && !self.refreshing && !self.loadingMore && self.nextCursor != nil
        }

        /// `lastVisiblePost`: index of the lowest post on screen.
        public func shouldLoadMore(lastVisiblePost: Int) -> Bool {
            return self.canLoadMore && !self.moreFailed && lastVisiblePost >= self.posts.count - 1 - Feed.prefetch
        }

        /// Returns the generation to pass back to `applyMore` / `failMore`.
        public func beginMore() -> Int {
            self.loadingMore = true
            self.moreFailed = false
            return self.generation
        }

        /// False when the page belongs to a list that was replaced meanwhile.
        @discardableResult
        public func applyMore(_ page: Page<Post>, generation: Int) -> Bool {
            if generation != self.generation {
                return false
            }
            SquareLogic.appendUnique(&self.posts, page.items)
            self.nextCursor = page.nextCursor
            self.loadingMore = false
            return true
        }

        public func failMore(generation: Int) {
            if generation != self.generation {
                return
            }
            self.loadingMore = false
            self.moreFailed = true
        }

        /// The reader leaves the tab (another tab, another page, the app in the background).
        public func markSeen(now: Int64) {
            self.seenAtMs = now
        }

        /// Whether to refresh when the tab is shown again: only when it was neither loaded nor
        /// looked at for `staleMs`. Someone who steps out for a moment comes back to the same
        /// posts at the same place, however long they had been reading before.
        public func isStale(now: Int64) -> Bool {
            return !self.loadedOnce || now - max(self.loadedAtMs, self.seenAtMs) >= Feed.staleMs
        }

        /// Posts changed on another page (a like, a comment): the ones in this list take the new
        /// counts in place; nothing is added, removed or moved, so the reader keeps their position.
        /// Returns how many posts changed.
        @discardableResult
        public func mergeSilently(_ fresh: [Post]) -> Int {
            var changed = 0
            for f in fresh {
                guard let i = self.posts.firstIndex(where: { $0.id == f.id }) else {
                    continue
                }
                let p = self.posts[i]
                if p.likeCount != f.likeCount || p.commentCount != f.commentCount || p.liked != f.liked || p.status != f.status || p.text != f.text {
                    changed += 1
                    self.posts[i].likeCount = f.likeCount
                    self.posts[i].commentCount = f.commentCount
                    self.posts[i].liked = f.liked
                    self.posts[i].status = f.status
                    self.posts[i].hiddenReason = f.hiddenReason
                    self.posts[i].text = f.text
                }
            }
            return changed
        }

        @discardableResult
        public func removePost(_ postId: String) -> Bool {
            guard let i = self.posts.firstIndex(where: { $0.id == postId }) else {
                return false
            }
            self.posts.remove(at: i)
            return true
        }

        @discardableResult
        public func removeAuthor(_ authorId: String) -> Int {
            let before = self.posts.count
            self.posts.removeAll(where: { $0.author.id == authorId })
            return before - self.posts.count
        }

        /// What goes under the posts.
        public var footer: Footer {
            if self.posts.isEmpty {
                if !self.loadedOnce {
                    return self.refreshFailed ? .firstError : .skeleton
                }
                if self.refreshing {
                    return .skeleton
                }
                if self.nextCursor == nil {
                    return .empty
                }
            }
            if self.moreFailed {
                return .moreError
            }
            return self.nextCursor != nil ? .loadingMore : .end
        }
    }

    /// One level of comments plus one level of replies: each comment followed by its replies, in
    /// server order. Replies to a reply are shown under the top comment; orphans become comments.
    public static func thread(_ comments: [Comment]) -> [Comment] {
        func find(_ id: String) -> Comment? {
            return comments.first(where: { $0.id == id })
        }
        func root(of c: Comment) -> Comment {
            var cur = c
            var guardCount = 0
            while let pid = cur.parentId, guardCount < 10, let parent = find(pid) {
                cur = parent
                guardCount += 1
            }
            return cur
        }
        let top = comments.filter { $0.parentId == nil || find($0.parentId!) == nil }
        var out: [Comment] = []
        for var t in top {
            t.depth = 0
            out.append(t)
            for var c in comments {
                if c.id == t.id || c.parentId == nil || top.contains(where: { $0.id == c.id }) {
                    continue
                }
                if root(of: c).id == t.id {
                    c.depth = 1
                    out.append(c)
                }
            }
        }
        return out
    }

    /// Top-level comment id to send as `parent_id` when replying to `c`.
    public static func replyParentId(_ all: [Comment], _ c: Comment) -> String {
        var cur = c
        var guardCount = 0
        while let pid = cur.parentId, guardCount < 10, let parent = all.first(where: { $0.id == pid }) {
            cur = parent
            guardCount += 1
        }
        return cur.id
    }

    // MARK: - permissions

    public static func canDeletePost(_ p: Post, myId: String?) -> Bool {
        guard let myId, !myId.isEmpty else {
            return false
        }
        return myId == p.author.id
    }

    /// The comment's author, or the author of the post it is under.
    public static func canDeleteComment(_ c: Comment, post: Post?, myId: String?) -> Bool {
        guard let myId, !myId.isEmpty else {
            return false
        }
        return myId == c.author.id || (post.map { $0.author.id == myId } ?? false)
    }

    // MARK: - validation

    public static func length(_ s: String?) -> Int {
        return s?.unicodeScalars.count ?? 0
    }

    /// Text ≤ 1000 characters; attachments are either up to 9 images or one video; something must be there.
    public static func isValidPost(text: String?, images: Int, hasVideo: Bool = false) -> Bool {
        let n = length(text?.trimmingCharacters(in: .whitespacesAndNewlines))
        if images < 0 || images > imagesMax || n > textMax {
            return false
        }
        if hasVideo && images > 0 {
            return false
        }
        return n > 0 || images > 0 || hasVideo
    }

    public static func isValidComment(_ text: String?) -> Bool {
        let n = length(text?.trimmingCharacters(in: .whitespacesAndNewlines))
        return n > 0 && n <= commentMax
    }

    /// Output size with the long edge ≤ `maxEdge` (default `imageMaxEdge`), keeping the aspect ratio.
    public static func scaledSize(width: Int, height: Int, maxEdge: Int = SquareLogic.imageMaxEdge) -> (width: Int, height: Int) {
        if width <= 0 || height <= 0 {
            return (0, 0)
        }
        let edge = max(width, height)
        if edge <= maxEdge {
            return (width, height)
        }
        let k = Double(maxEdge) / Double(edge)
        return (max(1, Int((Double(width) * k).rounded())), max(1, Int((Double(height) * k).rounded())))
    }

    /// Video output size: long edge ≤ `videoMaxEdge`, both sides even (H.264 needs that).
    public static func videoSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let s = scaledSize(width: width, height: height, maxEdge: videoMaxEdge)
        return (max(2, s.width / 2 * 2), max(2, s.height / 2 * 2))
    }

    /// Bitrate for the transcoded video: ~2.5 Mbps at 1280 px, scaled with the area, never above the source.
    public static func videoBitrate(width: Int, height: Int, sourceBitrate: Int) -> Int {
        let area = max(1, width) * max(1, height)
        let target = min(4_000_000, max(600_000, area * 2_500_000 / (1280 * 720)))
        return sourceBitrate > 0 ? min(target, sourceBitrate) : target
    }

    /// Whole seconds of a duration, rounded down (acceptance P3: 75.02 s is "1:15", not "1:16").
    public static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else {
            return 0
        }
        return Int(seconds.rounded(.down))
    }

    /// "0:07", "1:00", "12:34".
    public static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }

    public static func postBody(text: String?, imageKeys: [String]) -> [String: Any] {
        return ["text": (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "image_keys": imageKeys]
    }

    /// S11: `{text, video_key, cover_key}`; the server reads size, duration and format from the file.
    public static func postBody(text: String?, videoKey: String, coverKey: String) -> [String: Any] {
        return ["text": (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "video_key": videoKey, "cover_key": coverKey]
    }

    public static func commentBody(text: String?, parentId: String?) -> [String: Any] {
        var j: [String: Any] = ["text": (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
        if let parentId {
            j["parent_id"] = parentId
        }
        return j
    }

    /// S11: every slot declares its byte size; the PUT's Content-Length must match (S3 checks it).
    public static func uploadsBody(contentType: String, sizes: [Int]) -> [String: Any] {
        return ["count": sizes.count, "content_type": contentType, "sizes": sizes]
    }

    private static let component: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    static func urlEncode(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: component) ?? s
    }

    public static func feedPath(tab: String, cursor: String?) -> String {
        let t = (tab == tabHot || tab == tabRecommend) ? tab : tabLatest
        return "/v1/square/feed?tab=\(t)" + (cursor.map { "&cursor=" + urlEncode($0) } ?? "")
    }

    public static func withCursor(_ path: String, cursor: String?) -> String {
        guard let cursor else {
            return path
        }
        return path + (path.contains("?") ? "&" : "?") + "cursor=" + urlEncode(cursor)
    }

    public static func pathId(_ id: String) -> String {
        return urlEncode(id)
    }

    public static func postPath(_ id: String) -> String {
        return "/v1/square/posts/" + pathId(id)
    }

    public static func userPostsPath(_ userId: String) -> String {
        return "/v1/square/users/" + pathId(userId) + "/posts"
    }

    public static func userPath(_ userId: String) -> String {
        return "/v1/square/users/" + pathId(userId)
    }

    // MARK: - report

    public static let reportReasons = ["spam", "scam", "porn", "violence", "hate", "impersonation", "other"]

    public static func reportBody(target: String, id: String, reason: String) -> [String: Any] {
        return ["target": target, "id": id, "reason": reason]
    }

    // MARK: - silent link (S6)

    /// Bot username from the `t.me/<bot>?start=<nonce>` link, or nil.
    public static func botUsername(_ link: String?) -> String? {
        guard let link, let range = link.range(of: "t.me/") else {
            return nil
        }
        var s = String(link[range.upperBound...])
        if let end = s.firstIndex(where: { $0 == "?" || $0 == "/" || $0 == "#" }) {
            s = String(s[..<end])
        }
        guard !s.isEmpty, s.range(of: "^[A-Za-z0-9_]{4,32}$", options: .regularExpression) != nil else {
            return nil
        }
        return s
    }

    /// The message the app sends to the bot on the user's behalf.
    public static func startCommand(_ nonce: String) -> String {
        return "/start " + nonce
    }

    // MARK: - time

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseTime(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else {
            return nil
        }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }

    // MARK: - texts

    public struct Texts {
        let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        private func t(_ zhText: String, _ enText: String) -> String {
            return zh ? zhText : enText
        }

        public var title: String { t("广场", "Square") }
        public var latest: String { t("最新", "Latest") }
        public var hot: String { t("热门", "Hot") } // short: three tabs share the title of the iOS page
        public var recommend: String { t("推荐", "For you") }
        public var notInterested: String { t("不感兴趣", "Not interested") }
        public var notInterestedDone: String { t("将减少推荐类似内容", "You'll see fewer posts like this") }
        public var compose: String { t("发帖", "Post") }
        public var loadMore: String { t("加载更多", "Load more") }
        public var loading: String { t("正在加载…", "Loading…") }
        public var empty: String { t("还没有动态，来发第一条吧", "No posts yet. Be the first to share something.") }
        public var noMore: String { t("已经到底了", "You're all caught up") }
        public var refresh: String { t("刷新", "Refresh") }
        public var refreshing: String { t("正在刷新", "Refreshing") }
        /// Shown for a moment after a refresh; `n` posts were not in the list before.
        public func refreshed(_ n: Int) -> String {
            if n <= 0 {
                return t("已是最新内容", "You're up to date")
            }
            return zh ? "更新了 \(n) 条新内容" : (n == 1 ? "1 new post" : "\(n) new posts")
        }
        public var loadFailed: String { t("加载失败，请检查网络后重试", "Couldn't load. Check your connection and try again.") }
        public var retry: String { t("重试", "Try again") }
        public var moreFailed: String { t("加载失败，点击重试", "Couldn't load more. Tap to retry.") }

        public var hidden: String { t("已隐藏", "Hidden") }
        /// `reason` is a report reason code (S11: the most reported one) or free text.
        public func hiddenInfo(_ reason: String?) -> String {
            let base = t("这条动态已被隐藏，只有你自己能看到。", "This post has been hidden and is visible only to you.")
            guard let reason, !reason.isEmpty else {
                return base
            }
            let shown = SquareLogic.reportReasons.contains(reason) ? reportReason(reason) : reason
            return base + " " + t("原因：", "Reason: ") + shown
        }
        public func likes(_ n: Int) -> String { t("赞 \(n)", n == 1 ? "1 like" : "\(n) likes") }
        public func comments(_ n: Int) -> String { t("评论 \(n)", n == 1 ? "1 comment" : "\(n) comments") }
        public var like: String { t("赞", "Like") }
        public var unlike: String { t("取消赞", "Unlike") }
        public var comment: String { t("评论", "Comment") }
        public var reply: String { t("回复", "Reply") }
        public func replyTo(_ name: String) -> String { t("回复 " + name, "Reply to " + name) }
        public var commentHint: String { t("写下你的评论（最多 300 字）", "Write a comment (up to 300 characters)") }
        public var send: String { t("发送", "Send") }
        public var delete: String { t("删除", "Delete") }
        public var deletePostConfirm: String { t("删除这条动态？删除后无法恢复。", "Delete this post? This can't be undone.") }
        public var deleteCommentConfirm: String { t("删除这条评论？", "Delete this comment?") }
        public var deleted: String { t("已删除", "Deleted") }
        public var noComments: String { t("还没有评论，来说两句吧", "No comments yet. Start the conversation.") }
        public var commentsHeader: String { t("评论", "Comments") }
        public var commentsLoading: String { t("正在加载评论…", "Loading comments…") }
        public func replyingTo(_ name: String) -> String { t("正在回复 " + name, "Replying to " + name) }
        public var cancelReply: String { t("取消回复", "Cancel") }
        public var commentSent: String { t("评论已发布", "Comment posted") }
        public var postGone: String { t("这条动态已不存在", "This post is no longer available") }
        public var authorGone: String { t("找不到这位用户", "User not found") }
        public var noPublicUsername: String { t("对方没有公开用户名，暂时无法发消息", "This person hasn't set a public username, so you can't message them yet") }

        public var composeTitle: String { t("发动态", "New post") }
        public var textHint: String { t("分享新鲜事…（最多 1000 字）", "Share what's new… (up to 1000 characters)") }
        public var addAttachment: String { t("添加图片或视频", "Add photos or video") }
        public func addImages(_ n: Int) -> String { t("添加图片（\(n)/9）", "Add photos (\(n)/9)") }
        public var chooseImages: String { t("从相册选图片", "Choose photos") }
        public var chooseVideo: String { t("从相册选视频", "Choose a video") }
        public var takePhoto: String { t("拍照", "Take a photo") }
        public var recordVideo: String { t("录像", "Record a video") }
        public var removeImages: String { t("移除全部图片", "Remove all photos") }
        public var removeVideo: String { t("移除视频", "Remove video") }
        public func videoLabel(_ seconds: Int) -> String { t("视频 · " + SquareLogic.formatDuration(seconds), "Video · " + SquareLogic.formatDuration(seconds)) }
        public var publish: String { t("发布", "Post") }
        public var publishing: String { t("正在发布…", "Posting…") }
        public var uploadingVideo: String { t("正在上传视频…", "Uploading video…") }
        public func uploadingVideo(_ percent: Int) -> String { t("正在上传视频… \(percent)%", "Uploading video… \(percent)%") }
        public var published: String { t("已发布", "Posted") }
        public func attachmentsInfo(_ maxSeconds: Int) -> String {
            return t("最多 9 张图片，或 1 段不超过 \(maxSeconds) 秒的视频。图片会压缩到长边 2048 像素，视频会转码为 1280p 以内的 MP4；位置等元数据都会去掉后再上传。",
                     "Up to 9 photos, or one video of up to \(maxSeconds) seconds. Photos are resized to 2048 px on the long edge and videos are transcoded to MP4 at up to 1280p; location and other metadata are removed before upload.")
        }
        public var tooLong: String { t("内容超过了 1000 字", "The text is over 1000 characters") }
        public var needContent: String { t("写点什么，或添加图片 / 视频", "Add some text, photos or a video") }
        public var imageFailed: String { t("有图片无法处理，请换一张试试", "One of the photos couldn't be processed. Please try another.") }
        public var preparingImages: String { t("正在处理图片…", "Preparing photos…") }
        public var preparingVideo: String { t("正在处理视频…", "Preparing video…") }
        public var videoFailed: String { t("视频无法处理，请换一段试试", "The video couldn't be processed. Please try another.") }
        public func videoTooBig(_ maxMb: Int) -> String { t("转码后仍超过 \(maxMb) MB，请选一段更短的视频", "The video is still over \(maxMb) MB after compression. Please pick a shorter one.") }
        public var videoRejected: String { t("视频不符合要求（时长、大小或格式），请换一段试试", "The video doesn't meet the requirements (length, size or format). Please try another.") }
        public var squareDisabled: String { t("广场暂时不可用，请稍后再试", "Square is temporarily unavailable. Please try again later.") }
        public var videoTooLongTitle: String { t("视频超过时长限制", "Video is too long") }
        public func videoTooLong(_ maxSeconds: Int, _ actualSeconds: Int) -> String {
            return t("广场视频最长 \(maxSeconds) 秒，这段视频有 " + SquareLogic.formatDuration(actualSeconds) + "。可以只保留开头 \(maxSeconds) 秒继续发布。",
                     "Videos can be up to \(maxSeconds) seconds; this one is " + SquareLogic.formatDuration(actualSeconds) + ". You can keep the first \(maxSeconds) seconds and continue.")
        }
        public func trimAndContinue(_ maxSeconds: Int) -> String { t("保留前 \(maxSeconds) 秒", "Keep first \(maxSeconds) s") }
        public var onlyOneAttachmentType: String { t("一条动态只能带图片或视频中的一种", "A post can have either photos or a video, not both") }
        public func dailyLimitInfo(_ perDay: Int) -> String { t("每天最多发布 \(perDay) 条动态。", "You can post up to \(perDay) times a day.") }

        public var profileTitle: String { t("广场资料", "Square profile") }
        public var profileNeeded: String { t("先设置一下在广场显示的名字和简介，其他人会在你的动态上看到。", "Set the name and bio shown with your posts in Square.") }
        public var displayName: String { t("显示名", "Name") }
        public var bio: String { t("简介", "Bio") }
        public var publicUsername: String { t("公开用户名", "Public username") }
        public func useMyUsername(_ u: String) -> String { t("在广场显示 @" + u + "，其他人可以通过它给你发消息", "Show @" + u + " in Square so others can message you") }
        public var showUsername: String { t("显示", "Show") }
        public var useTelegramAvatar: String { t("在广场使用我的 Telegram 头像？", "Use your Telegram photo in Square?") }
        public var useTelegramAvatarText: String { t("其他人会在你的动态和名片上看到这张头像。", "Others will see this photo on your posts and profile.") }
        public var useAvatarYes: String { t("使用 Telegram 头像", "Use Telegram photo") }
        public var useAvatarNo: String { t("不使用", "Don't use") }
        public var hideUsername: String { t("不显示", "Don't show") }
        public var save: String { t("保存", "Save") }
        public var saved: String { t("已保存", "Saved") }
        public var editProfile: String { t("编辑广场资料", "Edit Square profile") }

        public var authorPosts: String { t("动态", "Posts") }
        public var sendMessage: String { t("发消息", "Message") }

        public var connecting: String { t("正在连接广场…", "Connecting to Square…") }
        public var connectFailed: String { t("暂时无法连接广场，请稍后再试", "Square isn't reachable right now. Please try again later.") }
        public var cancel: String { t("取消", "Cancel") }

        public var report: String { t("举报", "Report") }
        public var reportPost: String { t("举报这条动态", "Report post") }
        public var reportComment: String { t("举报这条评论", "Report comment") }
        public var reportAuthor: String { t("举报该用户", "Report user") }
        public var reportTitle: String { t("举报原因", "Why are you reporting this?") }
        public func reportReason(_ r: String) -> String {
            switch r {
            case "spam": return t("垃圾广告", "Spam")
            case "scam": return t("诈骗", "Scam or fraud")
            case "porn": return t("色情内容", "Sexual content")
            case "violence": return t("暴力内容", "Violence")
            case "hate": return t("仇恨言论", "Hate speech")
            case "impersonation": return t("冒充他人", "Impersonation")
            default: return t("其他", "Something else")
            }
        }
        public var reported: String { t("已收到你的举报，感谢反馈", "Thanks, your report has been received") }
        public var block: String { t("拉黑该用户", "Block user") }
        public func blockConfirm(_ name: String) -> String { t("拉黑后，你和 " + name + " 在广场和「附近的人」里都不会再看到对方。", "You and " + name + " will no longer see each other in Square or People Nearby.") }
        public var blocked: String { t("已拉黑", "Blocked") }
        public var more: String { t("更多", "More") }

        public var deleteMyData: String { t("删除我的广场数据", "Delete my Square data") }
        public var deleteMyDataConfirm: String { t("将删除你在广场发布的全部动态、评论、点赞和媒体文件，无法恢复。", "This permanently deletes all your Square posts, comments, likes and media.") }
        public var deletedMyData: String { t("你的广场数据已删除", "Your Square data has been deleted") }

        public func waitSeconds(_ seconds: Int) -> String {
            if seconds <= 0 {
                return t("操作太频繁，请稍后再试", "You're doing that too often. Please try again later.")
            }
            if seconds < 60 {
                return t("操作太频繁，请 \(seconds) 秒后再试", "You're doing that too often. Try again in \(seconds) s.")
            }
            let min = (seconds + 59) / 60
            if min < 60 {
                return t("操作太频繁，请 \(min) 分钟后再试", "You're doing that too often. Try again in \(min) min.")
            }
            let h = (min + 59) / 60
            return t("今天的发布次数已用完，请 \(h) 小时后再试", "You've reached today's posting limit. Try again in \(h) h.")
        }
        public var banned: String { t("你的账号暂时无法在广场发布内容", "Your account can't post in Square at the moment") }

        public func timeAgo(_ createdAt: Date?, now: Date) -> String {
            guard let createdAt else {
                return ""
            }
            let s = max(0, Int(now.timeIntervalSince(createdAt)))
            if s < 60 {
                return t("刚刚", "Just now")
            }
            if s < 3600 {
                return t("\(s / 60) 分钟前", "\(s / 60) min ago")
            }
            if s < 86400 {
                return t("\(s / 3600) 小时前", "\(s / 3600) h ago")
            }
            return t("\(s / 86400) 天前", "\(s / 86400) d ago")
        }
    }
}
