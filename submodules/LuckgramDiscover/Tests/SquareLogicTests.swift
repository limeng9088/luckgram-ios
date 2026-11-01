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
        XCTAssertEqual(p.likeCount, 3)
        XCTAssertEqual(p.commentCount, 0)
        XCTAssertTrue(p.liked)
        XCTAssertEqual(p.status, SquareLogic.statusApproved)
        XCTAssertNotNil(p.createdAt)
        XCTAssertNil(SquareLogic.parsePosts(["items": []]).nextCursor)
        XCTAssertNotNil(SquareLogic.parseTime("2026-11-01T10:00:00.123Z"))
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
        XCTAssertFalse(SquareLogic.isValidPost(text: "", images: 10))
        XCTAssertTrue(SquareLogic.isValidComment(" ok "))
        XCTAssertFalse(SquareLogic.isValidComment(""))
        XCTAssertFalse(SquareLogic.isValidComment(String(repeating: "a", count: 301)))
        XCTAssertEqual(SquareLogic.length("😀😀"), 2)
    }

    func testImageSizing() {
        XCTAssertTrue(SquareLogic.scaledSize(width: 4096, height: 3072) == (2048, 1536))
        XCTAssertTrue(SquareLogic.scaledSize(width: 3072, height: 4096) == (1536, 2048))
        XCTAssertTrue(SquareLogic.scaledSize(width: 800, height: 600) == (800, 600))
        XCTAssertTrue(SquareLogic.scaledSize(width: 100000, height: 10) == (2048, 1))
        XCTAssertTrue(SquareLogic.scaledSize(width: 0, height: 10) == (0, 0))
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
        XCTAssertNil(SquareLogic.commentBody(text: "x", parentId: nil)["parent_id"])
        XCTAssertEqual(SquareLogic.commentBody(text: "x", parentId: "c1")["parent_id"] as? String, "c1")
        XCTAssertEqual(SquareLogic.reportBody(target: "post", id: "p1", reason: "spam")["target"] as? String, "post")
        XCTAssertEqual(SquareLogic.reportReasons.count, 7)
        XCTAssertEqual(SquareLogic.uploadsBody(count: 2, contentType: "image/jpeg")["count"] as? Int, 2)
    }

    func testTextsCoverBothLanguagesAndWaitTimes() {
        let zh = SquareLogic.Texts(zh: true)
        let en = SquareLogic.Texts(zh: false)
        XCTAssertEqual(zh.title, "广场")
        XCTAssertEqual(en.title, "Square")
        XCTAssertEqual(zh.rejectedReason("x"), "未通过：x")
        XCTAssertEqual(en.rejectedReason(nil), "Not approved")
        XCTAssertTrue(zh.waitSeconds(30).contains("30 秒"))
        XCTAssertTrue(en.waitSeconds(90).contains("2 min"))
        XCTAssertTrue(zh.waitSeconds(7200).contains("小时"))
        XCTAssertTrue(en.waitSeconds(0).hasPrefix("Too many"))
        let now = Date()
        XCTAssertEqual(zh.timeAgo(now.addingTimeInterval(-1), now: now), "刚刚")
        XCTAssertEqual(en.timeAgo(now.addingTimeInterval(-3 * 3600), now: now), "3 h ago")
        XCTAssertEqual(en.timeAgo(nil, now: now), "")
        for r in SquareLogic.reportReasons {
            XCTAssertFalse(zh.reportReason(r).isEmpty)
            XCTAssertFalse(en.reportReason(r).isEmpty)
        }
        XCTAssertTrue(en.dailyLimitInfo(10).contains("10"))
    }
}
