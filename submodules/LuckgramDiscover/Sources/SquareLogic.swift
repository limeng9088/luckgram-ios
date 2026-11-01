import Foundation

/// Pure logic of "Square" (spec 26, server S11): response parsing, limits, image sizing, comment
/// threading, permissions and all texts in both languages. Foundation only (SwiftPM tests on
/// Linux); the same rules are in `org.telegram.luckgram.square.SquareLogic` on Android.
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

    public static let tabLatest = "latest"
    public static let tabHot = "hot"

    public static let statusPending = "pending"
    public static let statusApproved = "approved"
    public static let statusRejected = "rejected"

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

    public struct Post: Equatable {
        public var id: String = ""
        public var author = Author()
        public var text: String = ""
        public var images: [Image] = []
        public var likeCount: Int = 0
        public var commentCount: Int = 0
        public var liked: Bool = false
        public var createdAt: Date?
        public var status: String = SquareLogic.statusApproved
        public var rejectReason: String?

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
        public var status: String = SquareLogic.statusApproved
        public var rejectReason: String?
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
        p.likeCount = max(0, int(o, "like_count"))
        p.commentCount = max(0, int(o, "comment_count"))
        p.liked = bool(o, "liked")
        p.createdAt = parseTime(o["created_at"] as? String)
        p.status = normalizeStatus(o["status"] as? String)
        p.rejectReason = str(o, "reject_reason")
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
        c.rejectReason = str(o, "reject_reason")
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

    static func normalizeStatus(_ s: String?) -> String {
        if s == statusPending || s == statusRejected {
            return s!
        }
        return statusApproved
    }

    /// Appends a page without duplicates (cursor pages may overlap after new posts).
    public static func appendUnique(_ into: inout [Post], _ page: [Post]) {
        for p in page where !into.contains(where: { $0.id == p.id }) {
            into.append(p)
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

    public static func isValidPost(text: String?, images: Int) -> Bool {
        let n = length(text?.trimmingCharacters(in: .whitespacesAndNewlines))
        return images >= 0 && images <= imagesMax && n <= textMax && (n > 0 || images > 0)
    }

    public static func isValidComment(_ text: String?) -> Bool {
        let n = length(text?.trimmingCharacters(in: .whitespacesAndNewlines))
        return n > 0 && n <= commentMax
    }

    /// Output size with the long edge ≤ `imageMaxEdge`, keeping the aspect ratio.
    public static func scaledSize(width: Int, height: Int) -> (width: Int, height: Int) {
        if width <= 0 || height <= 0 {
            return (0, 0)
        }
        let edge = max(width, height)
        if edge <= imageMaxEdge {
            return (width, height)
        }
        let k = Double(imageMaxEdge) / Double(edge)
        return (max(1, Int((Double(width) * k).rounded())), max(1, Int((Double(height) * k).rounded())))
    }

    public static func postBody(text: String?, imageKeys: [String]) -> [String: Any] {
        return ["text": (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "image_keys": imageKeys]
    }

    public static func commentBody(text: String?, parentId: String?) -> [String: Any] {
        var j: [String: Any] = ["text": (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
        if let parentId {
            j["parent_id"] = parentId
        }
        return j
    }

    public static func uploadsBody(count: Int, contentType: String) -> [String: Any] {
        return ["count": count, "content_type": contentType]
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
        let t = tab == tabHot ? tabHot : tabLatest
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
        public var hot: String { t("热门", "Popular") }
        public var compose: String { t("发帖", "New post") }
        public var loadMore: String { t("加载更多", "Load more") }
        public var loading: String { t("正在加载…", "Loading…") }
        public var empty: String { t("还没有帖子", "No posts yet") }
        public var noMore: String { t("没有更多了", "That's all") }
        public var refresh: String { t("刷新", "Refresh") }

        public var pending: String { t("审核中", "Under review") }
        public var rejected: String { t("未通过", "Not approved") }
        public func rejectedReason(_ reason: String?) -> String {
            guard let reason, !reason.isEmpty else {
                return rejected
            }
            return t("未通过：" + reason, "Not approved: " + reason)
        }
        public func likes(_ n: Int) -> String { t("赞 \(n)", n == 1 ? "1 like" : "\(n) likes") }
        public func comments(_ n: Int) -> String { t("评论 \(n)", n == 1 ? "1 comment" : "\(n) comments") }
        public var like: String { t("赞", "Like") }
        public var unlike: String { t("取消赞", "Unlike") }
        public var comment: String { t("评论", "Comment") }
        public var reply: String { t("回复", "Reply") }
        public func replyTo(_ name: String) -> String { t("回复 " + name, "Reply to " + name) }
        public var commentHint: String { t("写评论（最多 300 字）", "Write a comment (up to 300 characters)") }
        public var send: String { t("发送", "Send") }
        public var delete: String { t("删除", "Delete") }
        public var deletePostConfirm: String { t("删除这条帖子？", "Delete this post?") }
        public var deleteCommentConfirm: String { t("删除这条评论？", "Delete this comment?") }
        public var deleted: String { t("已删除", "Deleted") }
        public var noComments: String { t("还没有评论", "No comments yet") }
        public var commentsHeader: String { t("评论", "Comments") }
        public var commentsLoading: String { t("正在加载评论…", "Loading comments…") }
        public func replyingTo(_ name: String) -> String { t("正在回复 " + name, "Replying to " + name) }
        public var cancelReply: String { t("取消回复", "Cancel reply") }
        public var commentSent: String { t("评论已发送", "Comment sent") }
        public var postGone: String { t("这条帖子已不存在", "This post is no longer available") }
        public var authorGone: String { t("找不到这位作者", "Author not found") }
        public var noPublicUsername: String { t("作者没有公开用户名，无法发消息", "This author has no public username, so you can't message them") }

        public var composeTitle: String { t("发帖", "New post") }
        public var textHint: String { t("说点什么（最多 1000 字）", "Say something (up to 1000 characters)") }
        public func addImages(_ n: Int) -> String { t("添加图片（\(n)/9）", "Add images (\(n)/9)") }
        public var removeImages: String { t("清空图片", "Remove images") }
        public func imagesSelected(_ n: Int) -> String { t("已选 \(n) 张图片", n == 1 ? "1 image selected" : "\(n) images selected") }
        public var publish: String { t("发布", "Post") }
        public var publishing: String { t("正在发布…", "Posting…") }
        public var published: String { t("已发布，审核通过后出现在广场", "Posted. It will appear in Square once it's approved.") }
        public var imagesInfo: String { t("图片会先压缩到长边 2048 像素，并去掉位置等 EXIF 信息再上传。", "Images are resized to 2048 px on the long edge and their EXIF data (including location) is removed before upload.") }
        public var tooLong: String { t("内容太长", "Too long") }
        public var needContent: String { t("写点文字或添加图片", "Add some text or images") }
        public var imageFailed: String { t("有图片处理失败，请换一张", "An image couldn't be processed. Try another one.") }
        public var preparingImages: String { t("正在处理图片…", "Preparing images…") }
        public func dailyLimitInfo(_ perDay: Int) -> String { t("每天最多发 \(perDay) 条帖子。", "Up to \(perDay) posts a day.") }

        public var profileTitle: String { t("广场名片", "Square profile") }
        public var profileNeeded: String { t("发帖前先填写广场名片，别人会在你的帖子上看到它。", "Fill in your Square profile first; others see it on your posts.") }
        public var displayName: String { t("显示名", "Name") }
        public var bio: String { t("简介", "Bio") }
        public var publicUsername: String { t("公开用户名（可选，别人可以给你发消息）", "Public username (optional, lets others message you)") }
        public func useMyUsername(_ u: String) -> String { t("显示 @" + u, "Show @" + u) }
        public var save: String { t("保存", "Save") }
        public var saved: String { t("已保存", "Saved") }
        public var editProfile: String { t("编辑广场名片", "Edit Square profile") }

        public var authorPosts: String { t("帖子", "Posts") }
        public var sendMessage: String { t("发消息", "Send message") }

        public var needLinkTitle: String { t("需要先绑定 Telegram 账号", "Link your Telegram account first") }
        public var needLinkText: String { t("浏览不需要绑定；发帖、点赞、评论和举报需要先在「Luckgram 功能 → 账号」里绑定。", "Browsing works without it; posting, liking, commenting and reporting need a linked account (Luckgram Features → Account).") }
        public var goLink: String { t("去绑定", "Link account") }
        public var cancel: String { t("取消", "Cancel") }

        public var report: String { t("举报", "Report") }
        public var reportPost: String { t("举报帖子", "Report post") }
        public var reportComment: String { t("举报评论", "Report comment") }
        public var reportAuthor: String { t("举报作者", "Report author") }
        public var reportTitle: String { t("举报原因", "Reason") }
        public func reportReason(_ r: String) -> String {
            switch r {
            case "spam": return t("垃圾信息", "Spam")
            case "scam": return t("诈骗", "Scam")
            case "porn": return t("色情", "Pornography")
            case "violence": return t("暴力", "Violence")
            case "hate": return t("仇恨", "Hate")
            case "impersonation": return t("冒充他人", "Impersonation")
            default: return t("其他", "Other")
            }
        }
        public var reported: String { t("已举报，感谢反馈", "Reported. Thank you.") }
        public var block: String { t("拉黑作者", "Block author") }
        public func blockConfirm(_ name: String) -> String { t("拉黑后你和 " + name + " 互相看不到对方的帖子和评论，「附近的人」里也互相不可见。", "You and " + name + " won't see each other's posts and comments, or each other in People Nearby.") }
        public var blocked: String { t("已拉黑", "Blocked") }
        public var more: String { t("更多", "More") }

        public var deleteMyData: String { t("删除我的广场数据", "Delete my Square data") }
        public var deleteMyDataConfirm: String { t("会删除你在广场的全部帖子、评论、点赞和图片，不能恢复。", "This deletes all your Square posts, comments, likes and images. It can't be undone.") }
        public var deletedMyData: String { t("已删除你的广场数据", "Your Square data was deleted") }

        public func waitSeconds(_ seconds: Int) -> String {
            if seconds <= 0 {
                return t("操作太频繁，请稍后再试", "Too many requests. Try again later.")
            }
            if seconds < 60 {
                return t("操作太频繁，请 \(seconds) 秒后再试", "Too many requests. Try again in \(seconds) s.")
            }
            let min = (seconds + 59) / 60
            if min < 60 {
                return t("操作太频繁，请 \(min) 分钟后再试", "Too many requests. Try again in \(min) min.")
            }
            let h = (min + 59) / 60
            return t("今天发帖已达上限，请 \(h) 小时后再试", "Daily post limit reached. Try again in \(h) h.")
        }
        public var banned: String { t("你的账号已被限制在广场发言", "Your account can't post in Square") }

        public func timeAgo(_ createdAt: Date?, now: Date) -> String {
            guard let createdAt else {
                return ""
            }
            let s = max(0, Int(now.timeIntervalSince(createdAt)))
            if s < 60 {
                return t("刚刚", "just now")
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
