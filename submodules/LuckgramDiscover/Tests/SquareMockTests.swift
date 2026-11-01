import XCTest
@testable import LuckgramDiscover

/// Square round trip through the in-app mock; same cases as DiscoverMockTest.squareRoundTrip on Android.
final class SquareMockTests: XCTestCase {
    private func b(_ s: String) -> Data {
        return s.data(using: .utf8)!
    }

    private func items(_ r: DiscoverMock.Reply?) -> [[String: Any]] {
        return r?.body["items"] as? [[String: Any]] ?? []
    }

    private func firstUpload(_ m: DiscoverMock, _ contentType: String) -> (key: String, url: String) {
        let ups = m.handle(method: "POST", path: "/v1/square/uploads", query: "", body: b("{\"count\":1,\"content_type\":\"\(contentType)\"}"))
        let u = (ups?.body["uploads"] as? [[String: Any]])?.first ?? [:]
        return (u["key"] as? String ?? "", u["url"] as? String ?? "")
    }

    func testSquareRoundTrip() {
        let m = DiscoverMock()
        m.setLinked(false)
        let feed = m.handle(method: "GET", path: "/v1/square/feed", query: "tab=latest", body: Data())
        XCTAssertEqual(items(feed).count, 20)
        let cursor = feed?.body["next_cursor"] as? String
        XCTAssertNotNil(cursor)
        let page2 = m.handle(method: "GET", path: "/v1/square/feed", query: "tab=latest&cursor=\(cursor!)", body: Data())
        XCTAssertEqual(items(page2).count, 5)
        XCTAssertNil(page2?.body["next_cursor"])
        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/posts", query: "", body: b("{\"text\":\"hi\"}"))?.status, 403)
        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/posts/p1/like", query: "", body: Data())?.status, 403)

        m.setLinked(true)
        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/posts", query: "", body: b("{\"text\":\"hi\"}"))?.status, 403)
        XCTAssertEqual(m.handle(method: "PUT", path: "/v1/square/profile", query: "", body: b("{\"display_name\":\"Me\",\"bio\":\"\",\"username\":\"\"}"))?.status, 200)
        let ups = m.handle(method: "POST", path: "/v1/square/uploads", query: "", body: b("{\"count\":2,\"content_type\":\"image/jpeg\"}"))
        let uploads = ups?.body["uploads"] as? [[String: Any]] ?? []
        XCTAssertEqual(uploads.count, 2)
        let key = uploads[0]["key"] as? String ?? ""
        let url = uploads[0]["url"] as? String ?? ""
        XCTAssertTrue(url.hasPrefix("https://\(DiscoverMock.mockHost)\(DiscoverMock.uploadPrefix)"))
        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/posts", query: "", body: b("{\"text\":\"hi\",\"image_keys\":[\"\(key)\"]}"))?.status, 400)
        XCTAssertTrue(m.acceptUpload(path: DiscoverMock.uploadPrefix + key, body: b("jpeg")))
        XCTAssertFalse(m.acceptUpload(path: DiscoverMock.uploadPrefix + "other/x.jpg", body: b("jpeg")))
        let posted = m.handle(method: "POST", path: "/v1/square/posts", query: "", body: b("{\"text\":\"hi\",\"image_keys\":[\"\(key)\"]}"))
        XCTAssertEqual(posted?.status, 200)
        XCTAssertEqual(posted?.body["status"] as? String, "published") // public at once, no review
        let id = posted?.body["id"] as? String ?? ""
        XCTAssertEqual(items(m.handle(method: "GET", path: "/v1/square/feed", query: "tab=latest", body: Data())).first?["id"] as? String, id)

        // a video post: one MP4 plus its cover, never together with images
        let v = firstUpload(m, "video/mp4")
        let cover = firstUpload(m, "image/jpeg")
        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/uploads", query: "", body: b("{\"count\":1,\"content_type\":\"video/quicktime\"}"))?.status, 400)
        XCTAssertTrue(v.key.hasSuffix(".mp4"))
        XCTAssertTrue(m.acceptUpload(path: DiscoverMock.uploadPrefix + v.key, body: b("mp4")))
        XCTAssertTrue(m.acceptUpload(path: DiscoverMock.uploadPrefix + cover.key, body: b("jpg")))
        let videoBody = "{\"text\":\"v\",\"video\":{\"key\":\"\(v.key)\",\"cover_key\":\"\(cover.key)\",\"width\":1280,\"height\":720,\"duration_seconds\":42}}"
        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/posts", query: "", body: b(videoBody.replacingOccurrences(of: "\"text\":\"v\"", with: "\"text\":\"v\",\"image_keys\":[\"\(key)\"]")))?.status, 400)
        let vposted = m.handle(method: "POST", path: "/v1/square/posts", query: "", body: b(videoBody))
        XCTAssertEqual(vposted?.status, 200)
        XCTAssertEqual((vposted?.body["video"] as? [String: Any])?["duration_seconds"] as? Int, 42)
        XCTAssertTrue(((vposted?.body["video"] as? [String: Any])?["cover_url"] as? String ?? "").contains("/mock-image/"))

        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/posts/\(id)/like", query: "", body: Data())?.body["like_count"] as? Int, 1)
        XCTAssertEqual(m.handle(method: "DELETE", path: "/v1/square/posts/\(id)/like", query: "", body: Data())?.body["like_count"] as? Int, 0)
        let c = m.handle(method: "POST", path: "/v1/square/posts/\(id)/comments", query: "", body: b("{\"text\":\"nice\"}"))?.body ?? [:]
        let cid = c["id"] as? String ?? ""
        XCTAssertEqual(c["status"] as? String, "published")
        let r = m.handle(method: "POST", path: "/v1/square/posts/\(id)/comments", query: "", body: b("{\"text\":\"re\",\"parent_id\":\"\(cid)\"}"))?.body ?? [:]
        XCTAssertEqual(r["parent_id"] as? String, cid)
        XCTAssertEqual(items(m.handle(method: "GET", path: "/v1/square/posts/\(id)/comments", query: "", body: Data())).count, 2)
        XCTAssertEqual(m.handle(method: "GET", path: "/v1/square/posts/\(id)", query: "", body: Data())?.body["comment_count"] as? Int, 2)
        XCTAssertEqual(m.handle(method: "DELETE", path: "/v1/square/comments/\(r["id"] as? String ?? "")", query: "", body: Data())?.status, 200)
        XCTAssertEqual(m.handle(method: "DELETE", path: "/v1/square/posts/p1", query: "", body: Data())?.status, 403)
        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/report", query: "", body: b("{\"target\":\"post\",\"id\":\"p1\",\"reason\":\"spam\"}"))?.status, 200)

        for _ in 0 ..< 3 {
            let _ = m.handle(method: "POST", path: "/v1/square/posts/\(id)/comments", query: "", body: b("{\"text\":\"x\"}"))
        }
        let limited = m.handle(method: "POST", path: "/v1/square/posts/\(id)/comments", query: "", body: b("{\"text\":\"x\"}"))
        XCTAssertEqual(limited?.status, 429)
        XCTAssertTrue(((limited?.body["error"] as? [String: Any])?["retry_after_seconds"] as? Int ?? 0) > 0)

        // three reports hide a post; its author still sees it, marked hidden, with the reason
        for _ in 0 ..< 3 {
            let _ = m.handle(method: "POST", path: "/v1/square/report", query: "", body: b("{\"target\":\"post\",\"id\":\"\(id)\",\"reason\":\"spam\"}"))
        }
        let hidden = m.handle(method: "GET", path: "/v1/square/posts/\(id)", query: "", body: Data())?.body ?? [:]
        XCTAssertEqual(hidden["status"] as? String, "hidden")
        XCTAssertNotNil(hidden["hidden_reason"])
        XCTAssertTrue(items(m.handle(method: "GET", path: "/v1/square/feed", query: "tab=latest", body: Data())).contains(where: { ($0["id"] as? String) == id }))

        XCTAssertEqual(m.handle(method: "POST", path: "/v1/blocks", query: "", body: b("{\"user\":\"m1\"}"))?.status, 200)
        for p in items(m.handle(method: "GET", path: "/v1/square/feed", query: "tab=hot", body: Data())) {
            XCTAssertNotEqual((p["author"] as? [String: Any])?["id"] as? String, "m1")
        }
        XCTAssertEqual(m.handle(method: "GET", path: "/v1/square/users/m1/posts", query: "", body: Data())?.status, 404)
        XCTAssertNotNil(m.handle(method: "GET", path: "/v1/square/users/m2", query: "", body: Data())?.body["author"])
        XCTAssertEqual(m.handle(method: "DELETE", path: "/v1/square/me", query: "", body: Data())?.status, 200)
        XCTAssertEqual(m.handle(method: "GET", path: "/v1/square/posts/\(id)", query: "", body: Data())?.status, 404)
        XCTAssertEqual(m.handle(method: "GET", path: "/v1/square/profile", query: "", body: Data())?.status, 404)
    }
}
