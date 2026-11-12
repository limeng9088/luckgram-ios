import XCTest
import LuckgramUI

/// specs#87 (29): perk rows, credits line, Pro-only summary ranges, skip survey.
final class LuckgramProPerksTests: XCTestCase {
    func testRowsFollowFixedOrderAndPerks() {
        let rows = LuckgramProPerks.rows(perks: ["no_ads", "ai", "agent_market", "unknown", "accounts"], numbers: .init(), zh: true)
        XCTAssertEqual(rows.map { $0.perk }, ["agent_market", "accounts", "ai", "no_ads"])
        XCTAssertEqual(rows.map { $0.proOnly }, [true, true, false, false])
        XCTAssertEqual(LuckgramProPerks.rows(perks: LuckgramProPerks.order, numbers: .init(), zh: false).count, 7)
        XCTAssertTrue(LuckgramProPerks.rows(perks: [], numbers: .init(), zh: true).isEmpty)
    }

    func testLivePerksPreferMeThenConfig() {
        XCTAssertEqual(LuckgramProPerks.livePerks(fromMe: ["ai", "ai"], fromConfig: "summary"), ["ai"])
        XCTAssertEqual(LuckgramProPerks.livePerks(fromMe: [], fromConfig: "summary, no_ads,"), ["summary", "no_ads"])
        XCTAssertEqual(LuckgramProPerks.livePerks(fromMe: [], fromConfig: "[\"ai\",\"translate\"]"), ["ai", "translate"])
        XCTAssertEqual(LuckgramProPerks.livePerks(fromMe: [], fromConfig: nil), [])
    }

    func testSubtitlesUseRemoteNumbers() {
        var n = LuckgramProPerks.Numbers()
        n.accountsMaxFree = 5
        n.chatPro = 500
        n.chatFree = 50
        n.monthlyCredits = 50
        n.summaryMaxPro = 1000
        n.translatePro = 2000
        n.translateFree = 200
        let zh = LuckgramProPerks.Texts(zh: true)
        XCTAssertEqual(zh.perkSubtitle("accounts", n), "同时登录的账号数量不限（免费 5 个）；账号备份加密存到云端。")
        XCTAssertEqual(zh.perkSubtitle("accounts", LuckgramProPerks.Numbers()), "同时登录的账号数量不限；账号备份加密存到云端。")
        XCTAssertEqual(zh.perkSubtitle("ai", n), "AI 对话每天 500 次（免费 50 次），每月另送 50 个 AI 点数，用于高级模型。")
        XCTAssertEqual(zh.perkSubtitle("summary", n), "总结最多 1000 条消息并可追问（免费 100 条）。")
        XCTAssertEqual(zh.perkSubtitle("translate", n), "每天翻译 2000 次（免费 200 次）。")
        XCTAssertEqual(zh.perkSubtitle("translate", .init()), "每天可翻译的次数更多。")
        for p in LuckgramProPerks.order {
            let all = zh.perkTitle(p) + zh.perkSubtitle(p, n) + LuckgramProPerks.Texts(zh: false).perkSubtitle(p, n)
            XCTAssertFalse(all.contains("自动续费"))
            XCTAssertFalse(all.lowercased().contains("auto-renew"))
        }
    }

    func testCreditsLine() {
        let utc = TimeZone(identifier: "UTC")!
        let resets = Date(timeIntervalSince1970: 1764460800) // 2025-11-30T00:00Z
        XCTAssertEqual(LuckgramProPerks.Texts(zh: true).creditsLine(remaining: 12, total: 50, resetsAt: resets, timeZone: utc), "本月 AI 点数 剩余 12 / 50，30 日重置")
        XCTAssertEqual(LuckgramProPerks.Texts(zh: false).creditsLine(remaining: 12, total: 50, resetsAt: resets, timeZone: utc), "AI credits this month: 12 / 50 left, resets Nov 30")
        XCTAssertEqual(LuckgramProPerks.Texts(zh: true).creditsValue(remaining: -3, total: 50, resetsAt: nil, timeZone: utc), "剩余 0 / 50")
    }

    func testSummaryRangesNeedPro() {
        XCTAssertFalse(LuckgramProPerks.summaryNeedsPro(count: 100, pro: false))
        XCTAssertTrue(LuckgramProPerks.summaryNeedsPro(count: 300, pro: false))
        XCTAssertTrue(LuckgramProPerks.summaryNeedsPro(count: 500, pro: false))
        XCTAssertFalse(LuckgramProPerks.summaryNeedsPro(count: 500, pro: true))
        XCTAssertEqual(LuckgramProPerks.summaryUnreadCap(unread: 800, pro: false, proMax: 1000), 100)
        XCTAssertEqual(LuckgramProPerks.summaryUnreadCap(unread: 800, pro: true, proMax: 1000), 800)
        XCTAssertEqual(LuckgramProPerks.summaryUnreadCap(unread: 5000, pro: true, proMax: 1000), 1000)
        XCTAssertEqual(LuckgramProPerks.summaryUnreadCap(unread: 40, pro: false, proMax: 1000), 40)
    }

    func testSurveyOnlyOnceFromOnboarding() {
        XCTAssertTrue(LuckgramProPerks.shouldShowSurvey(fromOnboarding: true, alreadyShown: false))
        XCTAssertFalse(LuckgramProPerks.shouldShowSurvey(fromOnboarding: true, alreadyShown: true))
        XCTAssertFalse(LuckgramProPerks.shouldShowSurvey(fromOnboarding: false, alreadyShown: false))
        XCTAssertEqual(LuckgramProPerks.surveyReason(0), "too_expensive")
        XCTAssertEqual(LuckgramProPerks.surveyReason(1), "prefer_free")
        XCTAssertEqual(LuckgramProPerks.surveyReason(2), "try_first")
        XCTAssertNil(LuckgramProPerks.surveyReason(nil))
        XCTAssertNil(LuckgramProPerks.surveyReason(3))
        XCTAssertEqual(LuckgramProPerks.Texts(zh: true).surveyOptions.count, 3)
    }
}
