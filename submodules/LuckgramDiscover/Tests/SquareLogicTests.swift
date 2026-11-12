import XCTest
@testable import LuckgramDiscover

/// Same cases as SquareLogicTest.java on Android.
final class SquareLogicTests: XCTestCase {
    private func c(_ id: String, _ parent: String?, _ author: String) -> SquareLogic.Comment {
        return SquareLogic.Comment(id: id, parentId: parent, author: SquareLogic.Author(id: author))
    }

    func testParsesPostsPageAndDropsBadImages() {
        let j: [String: Any] = [
            "items": [
                ["id": "p1", "author": ["id": "a", "display_name": "Alice", "username": "alice", "avatar_url": "http://x/a.png"],
                 "text": "hi", "images": [["url": "https://cdn/1.jpg", "width": 10, "height": 20], ["url": "ftp://bad"]],
                 "like_count": 3, "comment_count": -1, "liked": true, "created_at": "2026-11-01T10:00:00Z", "status": "weird"],
                ["id": ""]
            ],
            "next_cursor": "abc"
        ]
        let page = SquareLogic.parsePosts(j)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.nextCursor, "abc")
        let p = page.items[0]
        XCTAssertEqual(p.author.displayName, "Alice")
        XCTAssertNil(p.author.avatarUrl)
        XCTAssertEqual(p.images.count, 1)
        XCTAssertNil(p.video)
        XCTAssertEqual(p.likeCount, 3)
        XCTAssertEqual(p.commentCount, 0)
        XCTAssertTrue(p.liked)
        XCTAssertEqual(p.status, SquareLogic.statusPublished)
        XCTAssertFalse(p.isHidden)
        XCTAssertNotNil(p.createdAt)
        XCTAssertNil(SquareLogic.parsePosts(["items": []]).nextCursor)
        XCTAssertNotNil(SquareLogic.parseTime("2026-11-01T10:00:00.123Z"))
    }

    func testParsesHiddenAndVideo() {
        let p = SquareLogic.parsePost(["id": "p2", "status": "hidden", "hidden_reason": "spam",
                                       "images": [["url": "https://cdn/x.jpg"]],
                                       "video": ["url": "https://cdn/v.mp4", "cover_url": "https://cdn/c.jpg", "width": 1280, "height": 720, "duration_seconds": 42]])
        XCTAssertTrue(p.isHidden)
        XCTAssertEqual(p.hiddenReason, "spam")
        XCTAssertEqual(p.video?.durationSeconds, 42)
        XCTAssertEqual(p.video?.coverUrl, "https://cdn/c.jpg")
        XCTAssertTrue(p.images.isEmpty)
        XCTAssertNil(SquareLogic.parseVideo(["url": "http://plain/v.mp4"]))
        let c = SquareLogic.parseComment(["id": "c1", "status": "hidden", "reason": "x"])
        XCTAssertEqual(c.status, SquareLogic.statusHidden)
        XCTAssertEqual(c.hiddenReason, "x")
    }

    func testParsesUploads() {
        let u = SquareLogic.parseUploads(["uploads": [["key": "square/1.jpg", "url": "https://s3/1"], ["key": "square/2.jpg", "url": "http://s3/2"], ["url": "https://s3/3"]]])
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].key, "square/1.jpg")
        XCTAssertTrue(SquareLogic.parseUploads(nil).isEmpty)
    }

    func testAppendsWithoutDuplicates() {
        var into: [SquareLogic.Post] = []
        var a = SquareLogic.Post()
        a.id = "a"
        var b = SquareLogic.Post()
        b.id = "b"
        SquareLogic.appendUnique(&into, [a, b])
        SquareLogic.appendUnique(&into, [a, b])
        XCTAssertEqual(into.count, 2)
    }

    func testThreadsOneLevelOfReplies() {
        let c1 = c("c1", nil, "a")
        let r1 = c("r1", "c1", "b")
        let rr = c("rr", "r1", "c")
        let c2 = c("c2", nil, "d")
        let orphan = c("o", "missing", "e")
        let out = SquareLogic.thread([rr, c2, r1, c1, orphan]).map { "\($0.id):\($0.depth)" }
        XCTAssertEqual(out, ["c2:0", "c1:0", "rr:1", "r1:1", "o:0"])
        XCTAssertEqual(SquareLogic.replyParentId([c1, r1, rr], rr), "c1")
        XCTAssertEqual(SquareLogic.replyParentId([c1, r1, rr], c1), "c1")
    }

    func testPermissions() {
        var post = SquareLogic.Post()
        post.author.id = "owner"
        let mine = c("m", nil, "me")
        let other = c("o", nil, "x")
        XCTAssertTrue(SquareLogic.canDeletePost(post, myId: "owner"))
        XCTAssertFalse(SquareLogic.canDeletePost(post, myId: "me"))
        XCTAssertFalse(SquareLogic.canDeletePost(post, myId: nil))
        XCTAssertTrue(SquareLogic.canDeleteComment(mine, post: post, myId: "me"))
        XCTAssertTrue(SquareLogic.canDeleteComment(other, post: post, myId: "owner"))
        XCTAssertFalse(SquareLogic.canDeleteComment(other, post: post, myId: "me"))
        XCTAssertFalse(SquareLogic.canDeleteComment(other, post: nil, myId: ""))
    }

    func testValidation() {
        let long1000 = String(repeating: "字", count: 1000)
        XCTAssertTrue(SquareLogic.isValidPost(text: long1000, images: 0))
        XCTAssertFalse(SquareLogic.isValidPost(text: long1000 + "x", images: 0))
        XCTAssertFalse(SquareLogic.isValidPost(text: "   ", images: 0))
        XCTAssertTrue(SquareLogic.isValidPost(text: "", images: 1))
        XCTAssertTrue(SquareLogic.isValidPost(text: "", images: 0, hasVideo: true))
        XCTAssertFalse(SquareLogic.isValidPost(text: "", images: 10))
        XCTAssertFalse(SquareLogic.isValidPost(text: "x", images: 1, hasVideo: true))
        XCTAssertTrue(SquareLogic.isValidComment(" ok "))
        XCTAssertFalse(SquareLogic.isValidComment(""))
        XCTAssertFalse(SquareLogic.isValidComment(String(repeating: "a", count: 301)))
        XCTAssertEqual(SquareLogic.length("😀😀"), 2)
    }

    func testImageAndVideoSizing() {
        XCTAssertTrue(SquareLogic.scaledSize(width: 4096, height: 3072) == (2048, 1536))
        XCTAssertTrue(SquareLogic.scaledSize(width: 3072, height: 4096) == (1536, 2048))
        XCTAssertTrue(SquareLogic.scaledSize(width: 800, height: 600) == (800, 600))
        XCTAssertTrue(SquareLogic.scaledSize(width: 100000, height: 10) == (2048, 1))
        XCTAssertTrue(SquareLogic.scaledSize(width: 0, height: 10) == (0, 0))
        XCTAssertTrue(SquareLogic.videoSize(width: 1920, height: 1080) == (1280, 720))
        XCTAssertTrue(SquareLogic.videoSize(width: 1080, height: 1920) == (720, 1280))
        XCTAssertTrue(SquareLogic.videoSize(width: 640, height: 480) == (640, 480))
        XCTAssertTrue(SquareLogic.videoSize(width: 1921, height: 1079) == (1280, 718))
        XCTAssertEqual(SquareLogic.videoBitrate(width: 1280, height: 720, sourceBitrate: 0), 2_500_000)
        XCTAssertEqual(SquareLogic.videoBitrate(width: 1280, height: 720, sourceBitrate: 1_000_000), 1_000_000)
        XCTAssertEqual(SquareLogic.videoBitrate(width: 160, height: 120, sourceBitrate: 0), 600_000)
        XCTAssertEqual(SquareLogic.formatDuration(7), "0:07")
        XCTAssertEqual(SquareLogic.formatDuration(60), "1:00")
        XCTAssertEqual(SquareLogic.formatDuration(754), "12:34")
        // durations are rounded down everywhere (compose page, feed badge)
        XCTAssertEqual(SquareLogic.wholeSeconds(75.02), 75)
        XCTAssertEqual(SquareLogic.wholeSeconds(40.999), 40)
        XCTAssertEqual(SquareLogic.wholeSeconds(60.0), 60)
        XCTAssertEqual(SquareLogic.wholeSeconds(-5), 0)
        XCTAssertEqual(SquareLogic.wholeSeconds(.nan), 0)
        XCTAssertEqual(SquareLogic.formatDuration(SquareLogic.wholeSeconds(75.02)), "1:15")
    }

    func testPathsAndBodies() {
        XCTAssertEqual(SquareLogic.feedPath(tab: "nope", cursor: nil), "/v1/square/feed?tab=latest")
        XCTAssertEqual(SquareLogic.feedPath(tab: SquareLogic.tabHot, cursor: "a/b"), "/v1/square/feed?tab=hot&cursor=a%2Fb")
        XCTAssertEqual(SquareLogic.withCursor("/v1/square/users/x/posts", cursor: "1"), "/v1/square/users/x/posts?cursor=1")
        XCTAssertEqual(SquareLogic.pathId("a b"), "a%20b")
        XCTAssertEqual(SquareLogic.postPath("p1"), "/v1/square/posts/p1")
        let body = SquareLogic.postBody(text: "  hi ", imageKeys: ["k1", "k2"])
        XCTAssertEqual(body["text"] as? String, "hi")
        XCTAssertEqual((body["image_keys"] as? [String])?.count, 2)
        let vb = SquareLogic.postBody(text: "v", videoKey: "square/v.mp4", coverKey: "square/c.jpg")
        XCTAssertEqual(vb["video_key"] as? String, "square/v.mp4")
        XCTAssertEqual(vb["cover_key"] as? String, "square/c.jpg")
        XCTAssertNil(vb["image_keys"])
        let ub = SquareLogic.uploadsBody(contentType: SquareLogic.videoContentType, sizes: [1234])
        XCTAssertEqual(ub["content_type"] as? String, "video/mp4")
        XCTAssertEqual(ub["count"] as? Int, 1)
        XCTAssertEqual((ub["sizes"] as? [Int])?.first, 1234)
        XCTAssertNil(SquareLogic.commentBody(text: "x", parentId: nil)["parent_id"])
        XCTAssertEqual(SquareLogic.commentBody(text: "x", parentId: "c1")["parent_id"] as? String, "c1")
        XCTAssertEqual(SquareLogic.reportBody(target: "post", id: "p1", reason: "spam")["target"] as? String, "post")
        XCTAssertEqual(SquareLogic.reportReasons.count, 7)
    }

    func testSilentLinkHelpers() {
        XCTAssertEqual(SquareLogic.botUsername("https://t.me/LuckgramBot?start=abc"), "LuckgramBot")
        XCTAssertEqual(SquareLogic.botUsername("t.me/lg_bot/"), "lg_bot")
        XCTAssertNil(SquareLogic.botUsername("https://example.com/LuckgramBot?start=abc"))
        XCTAssertNil(SquareLogic.botUsername("https://t.me/?start=abc"))
        XCTAssertNil(SquareLogic.botUsername(nil))
        XCTAssertEqual(SquareLogic.startCommand("n0nce"), "/start n0nce")
    }

    func testTextsCoverBothLanguagesAndWaitTimes() {
        let zh = SquareLogic.Texts(zh: true)
        let en = SquareLogic.Texts(zh: false)
        XCTAssertEqual(zh.title, "广场")
        XCTAssertEqual(en.title, "Square")
        XCTAssertTrue(zh.hiddenInfo("x").contains("原因：x"))
        XCTAssertTrue(zh.hiddenInfo("spam").contains("垃圾广告"))
        XCTAssertTrue(en.hiddenInfo("hate").contains("Hate speech"))
        XCTAssertTrue(en.hiddenInfo(nil).hasPrefix("This post has been hidden"))
        XCTAssertTrue(zh.waitSeconds(30).contains("30 秒"))
        XCTAssertTrue(en.waitSeconds(90).contains("2 min"))
        XCTAssertTrue(zh.waitSeconds(7200).contains("小时"))
        XCTAssertTrue(en.waitSeconds(0).hasPrefix("You're doing that too often"))
        let now = Date()
        XCTAssertEqual(zh.timeAgo(now.addingTimeInterval(-1), now: now), "刚刚")
        XCTAssertEqual(en.timeAgo(now.addingTimeInterval(-3 * 3600), now: now), "3 h ago")
        XCTAssertEqual(en.timeAgo(nil, now: now), "")
        for r in SquareLogic.reportReasons {
            XCTAssertFalse(zh.reportReason(r).isEmpty)
            XCTAssertFalse(en.reportReason(r).isEmpty)
        }
        XCTAssertTrue(en.dailyLimitInfo(10).contains("10"))
        XCTAssertTrue(en.videoTooLong(60, 95).contains("1:35"))
        XCTAssertTrue(zh.attachmentsInfo(60).contains("60 秒"))
        XCTAssertEqual(zh.videoLabel(42), "视频 · 0:42")
        XCTAssertEqual(zh.useAvatarYes, "使用 Telegram 头像")
        XCTAssertEqual(en.useAvatarNo, "Don't use")
        for tx in [zh, en] {
            for s in [tx.connecting, tx.connectFailed, tx.needContent, tx.profileNeeded, tx.empty] {
                XCTAssertFalse(s.contains("绑定") || s.lowercased().contains("link"), s)
            }
        }
    }
    // MARK: - feed state

    private func post(_ id: String, _ author: String = "a") -> SquareLogic.Post {
        var p = SquareLogic.Post()
        p.id = id
        p.author = SquareLogic.Author(id: author)
        return p
    }

    private func page(_ cursor: String?, _ ids: String...) -> SquareLogic.Page<SquareLogic.Post> {
        var page = SquareLogic.Page<SquareLogic.Post>()
        page.items = ids.map { self.post($0) }
        page.nextCursor = cursor
        return page
    }

    private func ids(_ f: SquareLogic.Feed) -> String {
        return f.posts.map { $0.id }.joined(separator: " ")
    }

    func testRefreshKeepsTheListUntilTheNewPageArrives() {
        let f = SquareLogic.Feed(tab: SquareLogic.tabLatest)
        XCTAssertEqual(f.footer, .skeleton)
        XCTAssertTrue(f.beginRefresh())
        XCTAssertFalse(f.beginRefresh())
        XCTAssertEqual(f.applyRefresh(page("c1", "p3", "p2", "p1"), now: 1000), 0)
        XCTAssertEqual(ids(f), "p3 p2 p1")
        XCTAssertEqual(f.footer, .loadingMore)

        XCTAssertTrue(f.beginRefresh())
        XCTAssertEqual(ids(f), "p3 p2 p1")
        XCTAssertEqual(f.footer, .loadingMore)
        XCTAssertEqual(f.applyRefresh(page(nil, "p5", "p4", "p3"), now: 2000), 2)
        XCTAssertEqual(ids(f), "p5 p4 p3")
        XCTAssertFalse(f.refreshing)
        XCTAssertEqual(f.footer, .end)
        XCTAssertEqual(f.applyRefresh(page(nil, "p5", "p4", "p3"), now: 3000), 0)
    }

    func testFailedRefreshLeavesTheListAlone() {
        let f = SquareLogic.Feed(tab: SquareLogic.tabHot)
        _ = f.beginRefresh()
        f.failRefresh()
        XCTAssertEqual(f.footer, .firstError)
        XCTAssertTrue(f.isStale(now: 0))

        _ = f.beginRefresh()
        XCTAssertEqual(f.footer, .skeleton)
        f.applyRefresh(page("c", "p1", "p2"), now: 10)
        _ = f.beginRefresh()
        f.failRefresh()
        XCTAssertEqual(ids(f), "p1 p2")
        XCTAssertEqual(f.nextCursor, "c")
        XCTAssertEqual(f.footer, .loadingMore)
        XCTAssertTrue(f.beginRefresh())
    }

    func testLoadsMoreBeforeTheEndAndDropsPagesOfAReplacedList() {
        let f = SquareLogic.Feed(tab: SquareLogic.tabLatest)
        XCTAssertFalse(f.canLoadMore)
        _ = f.beginRefresh()
        f.applyRefresh(page("c1", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"), now: 0)
        XCTAssertFalse(f.shouldLoadMore(lastVisiblePost: 2))
        XCTAssertTrue(f.shouldLoadMore(lastVisiblePost: 7 - SquareLogic.Feed.prefetch))
        var g = f.beginMore()
        XCTAssertFalse(f.canLoadMore)
        XCTAssertTrue(f.applyMore(page(nil, "p8", "p9"), generation: g))
        XCTAssertEqual(ids(f), "p1 p2 p3 p4 p5 p6 p7 p8 p9")
        XCTAssertFalse(f.shouldLoadMore(lastVisiblePost: 8))
        XCTAssertEqual(f.footer, .end)

        _ = f.beginRefresh()
        f.applyRefresh(page("c2", "n1", "n2"), now: 0)
        g = f.beginMore()
        _ = f.beginRefresh()
        f.applyRefresh(page("c3", "m1"), now: 0)
        XCTAssertFalse(f.loadingMore)
        XCTAssertFalse(f.applyMore(page(nil, "n3"), generation: g))
        f.failMore(generation: g)
        XCTAssertFalse(f.moreFailed)
        XCTAssertEqual(ids(f), "m1")

        g = f.beginMore()
        f.failMore(generation: g)
        XCTAssertEqual(f.footer, .moreError)
        XCTAssertFalse(f.shouldLoadMore(lastVisiblePost: 0))
        XCTAssertTrue(f.canLoadMore)
    }

    func testStaleAfterFiveMinutesAndEmptyStates() {
        let f = SquareLogic.Feed(tab: SquareLogic.tabRecommend)
        _ = f.beginRefresh()
        f.applyRefresh(page(nil), now: 1000)
        XCTAssertEqual(f.footer, .empty)
        XCTAssertFalse(f.isStale(now: 1000 + SquareLogic.Feed.staleMs - 1))
        XCTAssertTrue(f.isStale(now: 1000 + SquareLogic.Feed.staleMs))
        _ = f.beginRefresh()
        XCTAssertEqual(f.footer, .skeleton)

        let left: Int64 = 1000 + 3 * SquareLogic.Feed.staleMs
        f.markSeen(now: left)
        XCTAssertFalse(f.isStale(now: left + 60_000))
        XCTAssertTrue(f.isStale(now: left + SquareLogic.Feed.staleMs))
    }

    func testQuietMergeUpdatesCountsInPlace() {
        let f = SquareLogic.Feed(tab: SquareLogic.tabLatest)
        _ = f.beginRefresh()
        f.applyRefresh(page("c", "p1", "p2", "p3"), now: 0)
        var liked = post("p2")
        liked.likeCount = 5
        liked.liked = true
        XCTAssertEqual(f.mergeSilently([post("p9"), liked, post("p3")]), 1)
        XCTAssertEqual(ids(f), "p1 p2 p3")
        XCTAssertEqual(f.posts[1].likeCount, 5)
        XCTAssertEqual(f.nextCursor, "c")

        f.posts[0].author = SquareLogic.Author(id: "b")
        XCTAssertEqual(f.removeAuthor("b"), 1)
        XCTAssertTrue(f.removePost("p3"))
        XCTAssertFalse(f.removePost("p3"))
        XCTAssertEqual(ids(f), "p2")
    }

    func testRefreshedTexts() {
        XCTAssertEqual(SquareLogic.Texts(zh: true).refreshed(3), "更新了 3 条新内容")
        XCTAssertEqual(SquareLogic.Texts(zh: true).refreshed(0), "已是最新内容")
        XCTAssertEqual(SquareLogic.Texts(zh: false).refreshed(1), "1 new post")
        XCTAssertEqual(SquareLogic.Texts(zh: false).refreshed(12), "12 new posts")
    }

    func testSavedFirstPageIsShownAtOnceAndRefreshedWhenOld() {
        let first: [String: Any] = ["items": [["id": "p1"], ["id": "p2"]], "next_cursor": "c"]
        let stored = SquareLogic.encodeSaved(first, now: 1000)
        XCTAssertNotNil(stored)
        guard let saved = SquareLogic.decodeSaved(stored, now: 2000) else {
            XCTFail("nothing decoded")
            return
        }
        XCTAssertEqual(saved.savedAtMs, 1000)

        let f = SquareLogic.Feed(tab: SquareLogic.tabLatest)
        XCTAssertTrue(f.restore(saved.page, savedAtMs: saved.savedAtMs))
        XCTAssertEqual(ids(f), "p1 p2")
        XCTAssertEqual(f.nextCursor, "c")
        XCTAssertEqual(f.footer, .loadingMore)
        XCTAssertFalse(f.isStale(now: 1000 + SquareLogic.Feed.staleMs - 1))
        XCTAssertTrue(f.isStale(now: 1000 + SquareLogic.Feed.staleMs))
        XCTAssertFalse(f.restore(saved.page, savedAtMs: saved.savedAtMs))

        XCTAssertTrue(f.beginRefresh())
        XCTAssertEqual(ids(f), "p1 p2")
        XCTAssertEqual(f.applyRefresh(page(nil, "p3", "p2"), now: 5000), 1)

        _ = f.beginRefresh()
        f.cancelLoading()
        XCTAssertTrue(f.beginRefresh())

        XCTAssertNil(SquareLogic.decodeSaved(nil, now: 0))
        XCTAssertNil(SquareLogic.decodeSaved("not json", now: 2000))
        XCTAssertNil(SquareLogic.decodeSaved(SquareLogic.encodeSaved(["items": [Any]()], now: 1000), now: 2000))
        XCTAssertNil(SquareLogic.decodeSaved(stored, now: 1000 + SquareLogic.savedMaxAgeMs + 1))
        XCTAssertNil(SquareLogic.decodeSaved(stored, now: 999))
    }
}
