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
        XCTAssertEqual(posted?.body["status"] as? String, "pending")
        let id = posted?.body["id"] as? String ?? ""
        XCTAssertEqual(m.handle(method: "GET", path: "/v1/square/posts/\(id)", query: "", body: Data())?.body["status"] as? String, "pending")

        XCTAssertEqual(m.handle(method: "POST", path: "/v1/square/posts/\(id)/like", query: "", body: Data())?.body["like_count"] as? Int, 1)
        XCTAssertEqual(m.handle(method: "DELETE", path: "/v1/square/posts/\(id)/like", query: "", body: Data())?.body["like_count"] as? Int, 0)
        let c = m.handle(method: "POST", path: "/v1/square/posts/\(id)/comments", query: "", body: b("{\"text\":\"nice\"}"))?.body ?? [:]
        let cid = c["id"] as? String ?? ""
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
