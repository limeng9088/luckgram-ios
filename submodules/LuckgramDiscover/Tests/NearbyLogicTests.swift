import XCTest
@testable import LuckgramDiscover

final class NearbyLogicTests: XCTestCase {
    func testCoarsensToTwoDecimals() {
        XCTAssertEqual(NearbyLogic.coord(31.230416), "31.23")
        XCTAssertEqual(NearbyLogic.coord(121.473701), "121.47")
        XCTAssertEqual(NearbyLogic.coord(-33.868820), "-33.87")
        XCTAssertEqual(NearbyLogic.coord(-0.001), "0.00")
        XCTAssertEqual(NearbyLogic.queryPath(lat: 31.230416, lon: 121.473701), "/v1/nearby?lat=31.23&lon=121.47")
        let body = NearbyLogic.cardBody(displayName: "A", bio: "bio", username: "alice", lat: 31.230416, lon: 121.473701, avatarBase64: nil)
        XCTAssertEqual("\(body["lat"]!)", "31.23")
        XCTAssertEqual("\(body["lon"]!)", "121.47")
        XCTAssertNil(body["avatar"])
        XCTAssertEqual(NearbyLogic.cardBody(displayName: "A", bio: "", username: "a", lat: 1, lon: 1, avatarBase64: "")["avatar"] as? String, "")
    }

    func testBioIsTrimmedAndCut() {
        XCTAssertEqual(NearbyLogic.cleanBio(String(repeating: "字", count: 80)).count, 70)
        XCTAssertEqual(NearbyLogic.cleanBio("  a\nb "), "a b")
        XCTAssertEqual(NearbyLogic.cleanBio(nil), "")
        XCTAssertEqual(NearbyLogic.cleanBio(String(repeating: "😀", count: 71)).count, 70)
    }

    func testPreconditions() {
        XCTAssertEqual(NearbyLogic.precondition(linked: false, username: "alice"), .needLink)
        XCTAssertEqual(NearbyLogic.precondition(linked: true, username: nil), .needUsername)
        XCTAssertEqual(NearbyLogic.precondition(linked: true, username: ""), .needUsername)
        XCTAssertEqual(NearbyLogic.precondition(linked: true, username: "alice"), .ready)
    }

    func testParsesListDropsSelfAndBadItems() {
        let j: [String: Any] = ["items": [
            ["id": "1", "display_name": "A", "bio": "x", "username": "a", "distance_bucket": "1km", "avatar_url": "https://cdn/x.jpg"],
            ["id": "2", "display_name": "Me", "username": "ME", "distance_bucket": "500m"],
            ["id": "", "username": "nobody"],
            ["id": "4", "username": "d", "distance_bucket": "weird", "avatar_url": "http://insecure"]
        ]]
        let l = NearbyLogic.parseList(j, selfUsername: "me")
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(l[0].avatarUrl, "https://cdn/x.jpg")
        XCTAssertEqual(l[1].displayName, "d")
        XCTAssertEqual(l[1].bucket, "far")
        XCTAssertNil(l[1].avatarUrl)
    }

    func testCapsAt100() {
        let items: [[String: Any]] = (0 ..< 150).map { ["id": "\($0)", "username": "u\($0)", "distance_bucket": "3km"] }
        XCTAssertEqual(NearbyLogic.parseList(["items": items], selfUsername: nil).count, 100)
    }

    func testGroupsInBucketOrderKeepingServerOrder() {
        let l = [("a", "far"), ("b", "500m"), ("c", "3km"), ("d", "500m")].map {
            NearbyLogic.Person(id: $0.0, displayName: $0.0, bio: "", username: $0.0, avatarUrl: nil, bucket: $0.1)
        }
        let g = NearbyLogic.group(l)
        XCTAssertEqual(g.map { $0.bucket }, ["500m", "3km", "far"])
        XCTAssertEqual(g[0].people.map { $0.id }, ["b", "d"])
    }

    func testExpiryAndReminder() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let exp = now.addingTimeInterval(24 * 3600)
        XCTAssertEqual(NearbyLogic.reminderAt(expiresAt: exp, now: now), exp.addingTimeInterval(-3600))
        XCTAssertNil(NearbyLogic.reminderAt(expiresAt: now.addingTimeInterval(1800), now: now))
        XCTAssertFalse(NearbyLogic.isExpired(exp, now: now))
        XCTAssertTrue(NearbyLogic.isExpired(exp, now: exp))
        XCTAssertTrue(NearbyLogic.isExpired(nil, now: now))
        let s = NearbyLogic.parseMe(["visible": true, "expires_at": "2026-11-02T08:00:00Z"])
        XCTAssertTrue(s.visible)
        XCTAssertEqual(s.expiresAt?.timeIntervalSince1970, 1793606400)
        XCTAssertFalse(NearbyLogic.parseMe(["visible": false]).visible)
    }

    func testTextsInBothLanguages() {
        let zh = NearbyLogic.Texts(zh: true)
        let en = NearbyLogic.Texts(zh: false)
        for b in NearbyLogic.buckets {
            XCTAssertNotEqual(zh.bucket(b), en.bucket(b))
        }
        for r in NearbyLogic.reportReasons {
            XCTAssertNotEqual(zh.reportReason(r), en.reportReason(r))
        }
        XCTAssertEqual(zh.bucket("500m"), "500 米内")
        XCTAssertEqual(en.bucket("1km"), "Within 1 km")
        XCTAssertTrue(zh.rateLimited(61).contains("2 分钟"))
        XCTAssertTrue(en.rateLimited(0).contains("1 min"))
    }
}

final class NearbyFixTests: XCTestCase {
    func testFixMustBeFresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(NearbyLogic.isFreshFix(now.addingTimeInterval(-29 * 60), now: now))
        XCTAssertTrue(NearbyLogic.isFreshFix(now.addingTimeInterval(-30 * 60), now: now))
        XCTAssertFalse(NearbyLogic.isFreshFix(now.addingTimeInterval(-31 * 60), now: now))
        XCTAssertFalse(NearbyLogic.isFreshFix(now.addingTimeInterval(10 * 60), now: now))
    }
}

final class DiscoverMockTests: XCTestCase {
    private func b(_ s: String) -> Data {
        return s.data(using: .utf8)!
    }

    func testNearbyRoundTrip() {
        let m = DiscoverMock()
        XCTAssertNil(m.handle(method: "GET", path: "/v1/ai/chat", query: nil, body: Data()))
        XCTAssertEqual(m.handle(method: "PUT", path: "/v1/nearby/me", query: nil, body: b("{\"lat\":31.2304,\"lon\":121.47,\"username\":\"me\"}"))?.status, 400)
        let put = m.handle(method: "PUT", path: "/v1/nearby/me", query: nil, body: b("{\"lat\":31.23,\"lon\":121.47,\"username\":\"me\"}"))
        XCTAssertEqual(put?.status, 200)
        XCTAssertEqual(put?.body["visible"] as? Bool, true)
        XCTAssertEqual(m.handle(method: "GET", path: "/v1/nearby/me", query: nil, body: Data())?.body["visible"] as? Bool, true)

        let items = m.handle(method: "GET", path: "/v1/nearby", query: "lat=31.23&lon=121.47", body: Data())?.body["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.count, 7)
        for o in items {
            XCTAssertNil(o["lat"])
            XCTAssertNil(o["distance"])
        }
        XCTAssertEqual(m.handle(method: "POST", path: "/v1/blocks", query: nil, body: b("{\"user\":\"m1\"}"))?.status, 200)
        XCTAssertEqual((m.handle(method: "GET", path: "/v1/nearby", query: "lat=31.23&lon=121.47", body: Data())?.body["items"] as? [Any])?.count, 6)
        XCTAssertEqual(m.handle(method: "DELETE", path: "/v1/blocks/m1", query: nil, body: Data())?.status, 200)
        XCTAssertEqual(m.handle(method: "DELETE", path: "/v1/nearby/me", query: nil, body: Data())?.status, 200)
        XCTAssertEqual(m.handle(method: "GET", path: "/v1/nearby/me", query: nil, body: Data())?.body["visible"] as? Bool, false)
    }

    func testNotLinkedAndRateLimit() {
        let m = DiscoverMock()
        _ = m.handle(method: "DELETE", path: "/v1/link", query: nil, body: Data())
        let r = m.handle(method: "GET", path: "/v1/nearby", query: "lat=1.00&lon=1.00", body: Data())
        XCTAssertEqual(r?.status, 403)
        XCTAssertEqual((r?.body["error"] as? [String: Any])?["code"] as? String, "not_linked")
        m.setLinked(true)
        for _ in 0 ..< 30 {
            _ = m.handle(method: "GET", path: "/v1/nearby", query: "lat=1.00&lon=1.00", body: Data())
        }
        let limited = m.handle(method: "GET", path: "/v1/nearby", query: "lat=1.00&lon=1.00", body: Data())
        XCTAssertEqual(limited?.status, 429)
        XCTAssertEqual((limited?.body["error"] as? [String: Any])?["retry_after_seconds"] as? Int, 1200)
    }

    func testCountsDecimals() {
        XCTAssertEqual(DiscoverMock.decimals("31.23"), 2)
        XCTAssertEqual(DiscoverMock.decimals("31"), 0)
        XCTAssertEqual(DiscoverMock.decimals("1e-05"), 99)
        XCTAssertEqual(DiscoverMock.decimals("1.0E-5"), 99)
        XCTAssertEqual(DiscoverMock.decimals("1E5"), 99)
    }
}

final class BlockLogicTests: XCTestCase {
    func testParseIdsDedupesAndToleratesObjects() {
        let json: [String: Any] = ["items": [["user": "a"], ["user": ["id": "b"]], ["user": "a"], ["user": ""], [:]], "next_cursor": "c1"]
        XCTAssertEqual(BlockLogic.parseIds(json), ["a", "b"])
        XCTAssertEqual(BlockLogic.nextCursor(json), "c1")
        XCTAssertNil(BlockLogic.nextCursor(["items": []]))
        XCTAssertNil(BlockLogic.nextCursor(["next_cursor": NSNull()]))
        XCTAssertEqual(BlockLogic.parseIds(nil), [])
    }

    func testPaths() {
        XCTAssertEqual(BlockLogic.listPath(cursor: nil), "/v1/blocks")
        XCTAssertEqual(BlockLogic.listPath(cursor: "a+b="), "/v1/blocks?cursor=a%2Bb%3D")
        XCTAssertEqual(BlockLogic.deletePath("u/1"), "/v1/blocks/u%2F1")
        XCTAssertEqual(BlockLogic.blockBody("u1")["user"] as? String, "u1")
    }

    func testNameCache() {
        var c = BlockLogic.putName([:], id: "a", name: " Alice ")
        c = BlockLogic.putName(c, id: "b", name: "Bob")
        XCTAssertEqual(c["a"], "Alice")
        c = BlockLogic.putName(c, id: "a", name: nil)
        XCTAssertNil(c["a"])
        XCTAssertNil(BlockLogic.putName(c, id: "b", name: "  ")["b"])
    }

    func testTextsBothLanguages() {
        XCTAssertEqual(BlockLogic.Texts(zh: true).title, "已拉黑的人")
        XCTAssertEqual(BlockLogic.Texts(zh: false).title, "Blocked People")
    }
}
