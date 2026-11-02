import XCTest
import LuckgramUI

final class LuckgramWelcomeLogicTests: XCTestCase {
    func testWelcomeOnlyWithoutAccounts() {
        XCTAssertTrue(LuckgramWelcomeLogic.shouldShowWelcome(otherAccounts: 0))
        XCTAssertFalse(LuckgramWelcomeLogic.shouldShowWelcome(otherAccounts: 1))
        XCTAssertFalse(LuckgramWelcomeLogic.shouldShowWelcome(otherAccounts: 2))
    }

    func testPrivacyAskedUntilAcceptedAndStepsOnce() {
        XCTAssertTrue(LuckgramWelcomeLogic.shouldAskPrivacy(accepted: false))
        XCTAssertFalse(LuckgramWelcomeLogic.shouldAskPrivacy(accepted: true))
        XCTAssertTrue(LuckgramWelcomeLogic.shouldShowSteps(onboarded: false))
        XCTAssertFalse(LuckgramWelcomeLogic.shouldShowSteps(onboarded: true))
    }

    func testPolicyUpdateAsksLoggedInUsersOnce() {
        XCTAssertFalse(LuckgramWelcomeLogic.shouldPromptUpdate(loggedIn: true, remoteVersion: 0, acceptedVersion: 0))
        XCTAssertTrue(LuckgramWelcomeLogic.shouldPromptUpdate(loggedIn: true, remoteVersion: 2, acceptedVersion: 1))
        XCTAssertTrue(LuckgramWelcomeLogic.shouldPromptUpdate(loggedIn: true, remoteVersion: 1, acceptedVersion: 0))
        XCTAssertFalse(LuckgramWelcomeLogic.shouldPromptUpdate(loggedIn: true, remoteVersion: 2, acceptedVersion: 2))
        XCTAssertFalse(LuckgramWelcomeLogic.shouldPromptUpdate(loggedIn: false, remoteVersion: 2, acceptedVersion: 1))
        XCTAssertTrue(LuckgramWelcomeLogic.Texts(zh: true).privacyUpdatedTitle.contains("已更新"))
    }

    func testPrivacyURLByLanguageUnlessConfigured() {
        XCTAssertEqual(LuckgramWelcomeLogic.privacyURL(nil, zh: true), "https://luckgram.cc/privacy-policy/")
        XCTAssertEqual(LuckgramWelcomeLogic.privacyURL("", zh: false), "https://luckgram.cc/en/privacy-policy/")
        XCTAssertEqual(LuckgramWelcomeLogic.privacyURL("http://luckgram.cc/x", zh: false), "https://luckgram.cc/en/privacy-policy/")
        XCTAssertEqual(LuckgramWelcomeLogic.privacyURL(" https://luckgram.cc/legal/privacy ", zh: true), "https://luckgram.cc/legal/privacy")
    }

    func testProStepAlwaysLastAndSubscribeOnlyWithBilling() {
        XCTAssertEqual(LuckgramWelcomeLogic.steps(), [.ai, .agents, .summary, .discover, .pro])
        XCTAssertTrue(LuckgramWelcomeLogic.canSubscribe(.pro, billingEnabled: true))
        XCTAssertFalse(LuckgramWelcomeLogic.canSubscribe(.pro, billingEnabled: false))
        XCTAssertFalse(LuckgramWelcomeLogic.canSubscribe(.ai, billingEnabled: true))
        XCTAssertEqual(LuckgramWelcomeLogic.Texts(zh: true).comingSoon, "即将推出")
        XCTAssertEqual(LuckgramWelcomeLogic.Texts(zh: false).comingSoon, "Coming soon")
    }

    func testProgressCountsShownSteps() {
        XCTAssertEqual(LuckgramWelcomeLogic.progress(index: 0, total: 4), "1/4")
        XCTAssertEqual(LuckgramWelcomeLogic.progress(index: 4, total: 5), "5/5")
        XCTAssertEqual(LuckgramWelcomeLogic.progressFraction(index: 0, total: 4), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LuckgramWelcomeLogic.progressFraction(index: 3, total: 4), 1.0, accuracy: 0.0001)
    }

    func testStepsWriteTheirFeatureSwitches() {
        XCTAssertEqual(LuckgramWelcomeLogic.toggles(.ai), ["translate_out", "quick_replies", "ai_reply", "ai_writing"])
        XCTAssertEqual(LuckgramWelcomeLogic.toggles(.agents), ["ai_agents"])
        XCTAssertTrue(LuckgramWelcomeLogic.toggles(.summary).isEmpty)
        XCTAssertTrue(LuckgramWelcomeLogic.toggles(.discover).isEmpty)
        XCTAssertTrue(LuckgramWelcomeLogic.hasSecondary(.ai))
        XCTAssertTrue(LuckgramWelcomeLogic.hasSecondary(.pro))
        XCTAssertFalse(LuckgramWelcomeLogic.hasSecondary(.summary))
    }

    func testTextsInBothLanguages() {
        let zh = LuckgramWelcomeLogic.Texts(zh: true)
        let en = LuckgramWelcomeLogic.Texts(zh: false)
        XCTAssertEqual(zh.getStarted, "开始使用")
        XCTAssertEqual(en.getStarted, "Get Started")
        XCTAssertEqual(en.welcomeTo, "Welcome to")
        XCTAssertEqual(en.privacyTitle, "Luckgram Privacy Policy")
        XCTAssertEqual(en.privacyText.components(separatedBy: "\n\n").count, 3)
        XCTAssertEqual(zh.privacyText.components(separatedBy: "\n\n").count, 3)
        XCTAssertTrue(zh.privacyText.contains("非官方"))
        XCTAssertEqual(zh.secondary(.ai), "暂不开启")
        XCTAssertNil(en.secondary(.summary))
        XCTAssertNil(en.question(.discover))
        XCTAssertEqual(en.subscribe(stars: 250, days: 30), "Subscribe · 250 ⭐ / 30 days")
        XCTAssertEqual(zh.subscribe(stars: 0, days: 30), "订阅")
        for s in LuckgramWelcomeLogic.Step.allCases {
            XCTAssertFalse(zh.title(s).isEmpty)
            XCTAssertFalse(en.body(s).isEmpty)
        }
        // Only benefits Luckgram Pro really has (S7): AI quota, device sharing, Stars.
        XCTAssertEqual(en.proFeatures.count, 3)
    }
}
