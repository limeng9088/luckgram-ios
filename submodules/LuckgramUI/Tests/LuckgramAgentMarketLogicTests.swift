import XCTest
import LuckgramUI

/// specs#88 (30): S13 parsing, request paths, cache / offline search, "我的" list, Pro gate (same cases as Android).
final class LuckgramAgentMarketLogicTests: XCTestCase {
    private var page: [String: Any] {
        return [
            "items": [
                ["id": "email-pro", "name": ["zh": "职场邮件", "en": "Work email"], "description": ["zh": "写邮件", "en": "Writes emails"],
                 "category": "work", "avatar": ["color": "#475569", "emoji": "📧"], "examples": [["zh": "请假邮件", "en": "Leave email"]],
                 "author": "luckgram", "pro_only": false, "model_tier": "standard", "users": 12345, "instruction": "SECRET"] as [String: Any],
                ["id": "translator-x", "name": ["zh": "翻译官", "en": "Translator"], "description": ["zh": "中英互译", "en": "Translate"],
                 "category": "study", "avatar": ["color": "bad"], "pro_only": true, "model_tier": "premium", "users": 3] as [String: Any],
                ["name": ["zh": "没有 id"]] as [String: Any]
            ],
            "next_cursor": "bzIw"
        ]
    }

    func testParsesPageWithoutInstruction() throws {
        let p = LuckgramAgentMarketLogic.parsePage(self.page)
        XCTAssertEqual(p.items.count, 2)
        XCTAssertEqual(p.nextCursor, "bzIw")
        let a = p.items[0]
        XCTAssertEqual(a.name.pick(chinese: true), "职场邮件")
        XCTAssertEqual(a.name.pick(chinese: false), "Work email")
        XCTAssertEqual(a.color, 0x475569)
        XCTAssertEqual(a.avatarText(chinese: true), "📧")
        XCTAssertEqual(a.examples.count, 1)
        XCTAssertEqual(a.users, 12345)
        let encoded = String(data: try JSONEncoder().encode(a), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("SECRET"))
        let b = p.items[1]
        XCTAssertEqual(b.color, LuckgramAgentMarketLogic.defaultColor)
        XCTAssertTrue(b.proOnly)
        XCTAssertTrue(b.isPremium)
        XCTAssertEqual(b.avatarText(chinese: true), "翻")
        XCTAssertNil(LuckgramAgentMarketLogic.parsePage(["items": [Any](), "next_cursor": NSNull()]).nextCursor)
    }

    func testCategories() {
        let c = LuckgramAgentMarketLogic.parseCategories(["categories": [["id": "writing", "name": ["zh": "写作", "en": "Writing"], "count": 4] as [String: Any], ["name": [String: Any]()]]])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].name.pick(chinese: true), "写作")
        XCTAssertEqual(c[0].count, 4)
    }

    func testPaths() {
        XCTAssertEqual(LuckgramAgentMarketLogic.listPath(category: "", query: " ", cursor: nil, limit: 20), "/v1/agents?limit=20")
        XCTAssertEqual(LuckgramAgentMarketLogic.listPath(category: "work", query: "翻译", cursor: "bzIw", limit: 20), "/v1/agents?limit=20&category=work&q=%E7%BF%BB%E8%AF%91&cursor=bzIw")
        XCTAssertEqual(LuckgramAgentMarketLogic.listPath(category: nil, query: "a b", cursor: "", limit: 5), "/v1/agents?limit=5&q=a%20b")
        let long = String(repeating: "x", count: 60)
        XCTAssertTrue(LuckgramAgentMarketLogic.listPath(category: nil, query: long, cursor: nil, limit: 5).hasSuffix("&q=" + String(repeating: "x", count: 50)))
        XCTAssertEqual(LuckgramAgentMarketLogic.detailPath("email-pro"), "/v1/agents/email-pro")
        XCTAssertEqual(LuckgramAgentMarketLogic.chatParams(agentId: "email-pro"), ["agent_id": "email-pro"])
        XCTAssertEqual(LuckgramAgentMarketLogic.conversationKey("email-pro"), "market:email-pro")
    }

    func testSearch() {
        let a = LuckgramAgentMarketLogic.parsePage(self.page).items[1]
        XCTAssertTrue(a.matches("翻译"))
        XCTAssertTrue(a.matches("TRANSL"))
        XCTAssertTrue(a.matches(""))
        XCTAssertFalse(a.matches("邮件"))
    }

    func testCacheAndOffline() {
        var c = LuckgramAgentMarketLogic.Cache()
        c.putFirstPage(category: "", LuckgramAgentMarketLogic.parsePage(self.page))
        c.categories = LuckgramAgentMarketLogic.parseCategories(["categories": [["id": "work", "name": ["zh": "工作", "en": "Work"], "count": 1] as [String: Any]]])
        let back = LuckgramAgentMarketLogic.Cache.decode(c.encoded())
        XCTAssertEqual(back.firstPage(category: "")?.items.count, 2)
        XCTAssertEqual(back.categories.count, 1)
        XCTAssertEqual(back.offline(category: "", query: "").count, 2)
        XCTAssertEqual(back.offline(category: "work", query: "").count, 1)
        XCTAssertEqual(back.offline(category: "", query: "翻译").first?.id, "translator-x")
        XCTAssertEqual(back.offline(category: "work", query: "翻译").count, 0)
        XCTAssertEqual(back.detail("email-pro")?.id, "email-pro")
        XCTAssertNil(back.detail("nope"))
        XCTAssertEqual(LuckgramAgentMarketLogic.Cache.decode("not json").allAgents().count, 0)
    }

    func testUsedList() {
        let items = LuckgramAgentMarketLogic.parsePage(self.page).items
        var used: [LuckgramAgentMarketLogic.Agent] = []
        used = LuckgramAgentMarketLogic.markUsed(used, items[0])
        used = LuckgramAgentMarketLogic.markUsed(used, items[1])
        used = LuckgramAgentMarketLogic.markUsed(used, items[0])
        XCTAssertEqual(used.map { $0.id }, ["email-pro", "translator-x"])
        let back = LuckgramAgentMarketLogic.decodeUsed(LuckgramAgentMarketLogic.encodeUsed(used))
        XCTAssertEqual(back[1].id, "translator-x")
        XCTAssertEqual(back[0].emoji, "📧")
        XCTAssertEqual(LuckgramAgentMarketLogic.removeUsed(back, id: "email-pro").count, 1)
        XCTAssertEqual(LuckgramAgentMarketLogic.decodeUsed("garbage").count, 0)
    }

    func testProGate() {
        let items = LuckgramAgentMarketLogic.parsePage(self.page).items
        XCTAssertFalse(LuckgramAgentMarketLogic.needsUpgrade(items[0], isPro: false))
        XCTAssertTrue(LuckgramAgentMarketLogic.needsUpgrade(items[1], isPro: false))
        XCTAssertFalse(LuckgramAgentMarketLogic.needsUpgrade(items[1], isPro: true))
    }

    func testUsers() {
        XCTAssertEqual(LuckgramAgentMarketLogic.formatUsers(12, chinese: true), "12人使用")
        XCTAssertEqual(LuckgramAgentMarketLogic.formatUsers(12345, chinese: true), "1.2万人使用")
        XCTAssertEqual(LuckgramAgentMarketLogic.formatUsers(1, chinese: false), "1 user")
        XCTAssertEqual(LuckgramAgentMarketLogic.formatUsers(12345, chinese: false), "12.3K users")
        XCTAssertEqual(LuckgramAgentMarketLogic.formatUsers(2_000_000, chinese: false), "2M users")
    }
}
