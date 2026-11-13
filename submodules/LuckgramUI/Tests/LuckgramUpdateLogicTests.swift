import XCTest
@testable import LuckgramUI

final class LuckgramUpdateLogicTests: XCTestCase {
    private let hour: TimeInterval = 60 * 60

    func testCompareVersions() {
        XCTAssertEqual(LuckgramUpdateLogic.compareVersions("13.0", "13.0.0"), 0)
        XCTAssertEqual(LuckgramUpdateLogic.compareVersions("13.0.3", "13.0.10"), -1)
        XCTAssertEqual(LuckgramUpdateLogic.compareVersions("13.1", "13.0.99"), 1)
        XCTAssertEqual(LuckgramUpdateLogic.compareVersions("2", "1.9.9.9"), 1)
        XCTAssertEqual(LuckgramUpdateLogic.compareVersions("garbage", "0"), 0)
        XCTAssertEqual(LuckgramUpdateLogic.compareVersions("", "0.0.1"), -1)
    }

    func testNewerByBuildOnlyWhenBothKnown() {
        XCTAssertTrue(LuckgramUpdateLogic.isNewer(latest: "12.2", latestBuild: 900, current: "12.2", currentBuild: 800))
        XCTAssertFalse(LuckgramUpdateLogic.isNewer(latest: "12.2", latestBuild: 800, current: "12.2", currentBuild: 900))
        XCTAssertFalse(LuckgramUpdateLogic.isNewer(latest: "12.2", latestBuild: 900, current: "12.2", currentBuild: 0))
        XCTAssertFalse(LuckgramUpdateLogic.isNewer(latest: "12.2", latestBuild: 0, current: "12.2", currentBuild: 800))
        XCTAssertTrue(LuckgramUpdateLogic.isNewer(latest: "12.2.1", latestBuild: 1, current: "12.2", currentBuild: 999))
        XCTAssertFalse(LuckgramUpdateLogic.isNewer(latest: "12.1", latestBuild: 999, current: "12.2", currentBuild: 1))
    }

    func testCheckAtMostOncePerHour() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertTrue(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: nil, lastFailure: nil))
        XCTAssertFalse(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: now.addingTimeInterval(-59 * 60), lastFailure: nil))
        XCTAssertTrue(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: now.addingTimeInterval(-hour), lastFailure: nil))
        XCTAssertTrue(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: now.addingTimeInterval(hour), lastFailure: nil))
        XCTAssertFalse(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: nil, lastFailure: now.addingTimeInterval(-hour / 2)))
        XCTAssertTrue(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: nil, lastFailure: now.addingTimeInterval(-hour)))
    }

    func testPath() {
        XCTAssertEqual(LuckgramUpdateLogic.path(platform: "ios", appVersion: "12.2", build: 900), "/v1/version?platform=ios&app_version=12.2&build=900")
        XCTAssertEqual(LuckgramUpdateLogic.path(platform: "ios", appVersion: "12.2", build: 0), "/v1/version?platform=ios&app_version=12.2")
        XCTAssertEqual(LuckgramUpdateLogic.path(platform: "ios", appVersion: "12.2&x=1", build: 900), "/v1/version?platform=ios")
        XCTAssertEqual(LuckgramUpdateLogic.path(platform: "ios", appVersion: nil, build: 900), "/v1/version?platform=ios")
    }

    private func info(_ latest: String, _ build: Int64, _ min: String, _ url: String) -> LuckgramUpdateLogic.Info {
        return LuckgramUpdateLogic.Info(latest: latest, build: build, min: min, url: url, notesZh: "修复问题", notesEn: "Bug fixes")
    }

    func testEvaluate() {
        let url = "https://example.com/releases/tag/ios-12.3"
        var s = LuckgramUpdateLogic.evaluate(info("12.3", 950, "12.0", url), current: "12.2", currentBuild: 900, chinese: true)
        XCTAssertTrue(s.updateAvailable)
        XCTAssertFalse(s.forceUpdate)
        XCTAssertEqual(s.latest, "12.3")
        XCTAssertEqual(s.url, url)
        XCTAssertEqual(s.notes, "修复问题")
        XCTAssertEqual(LuckgramUpdateLogic.evaluate(info("12.3", 950, "12.0", url), current: "12.2", currentBuild: 900, chinese: false).notes, "Bug fixes")

        XCTAssertEqual(LuckgramUpdateLogic.evaluate(info("12.2", 900, "12.0", url), current: "12.2", currentBuild: 900, chinese: true), LuckgramUpdateLogic.State.hidden)
        XCTAssertEqual(LuckgramUpdateLogic.evaluate(info("12.3", 950, "", url), current: "12.3", currentBuild: 950, chinese: true), LuckgramUpdateLogic.State.hidden)

        s = LuckgramUpdateLogic.evaluate(info("12.4", 990, "12.3", url), current: "12.2", currentBuild: 900, chinese: true)
        XCTAssertTrue(s.forceUpdate)
        XCTAssertTrue(s.updateAvailable)
        XCTAssertFalse(LuckgramUpdateLogic.evaluate(info("12.4", 990, "12.2", url), current: "12.2", currentBuild: 900, chinese: true).forceUpdate)

        XCTAssertEqual(LuckgramUpdateLogic.evaluate(info("12.4", 990, "12.3", "http://example.com/x"), current: "12.2", currentBuild: 900, chinese: true), LuckgramUpdateLogic.State.hidden)
        XCTAssertEqual(LuckgramUpdateLogic.evaluate(info("12.4", 990, "12.3", ""), current: "12.2", currentBuild: 900, chinese: true), LuckgramUpdateLogic.State.hidden)
        XCTAssertEqual(LuckgramUpdateLogic.evaluate(nil, current: "12.2", currentBuild: 900, chinese: true), LuckgramUpdateLogic.State.hidden)
    }

    func testParseAndPersist() throws {
        let data = #"{"platform":"ios","latest":"12.3","build":950,"min":"12.0","url":"https://example.com/x","notes":{"zh":"中","en":"en"},"update_available":true,"force_update":false}"#.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parsed = LuckgramUpdateLogic.parse(json)
        let i = LuckgramUpdateLogic.deserialize(LuckgramUpdateLogic.serialize(parsed))
        XCTAssertEqual(i, parsed)
        XCTAssertEqual(i?.latest, "12.3")
        XCTAssertEqual(i?.build, 950)
        XCTAssertEqual(i?.min, "12.0")
        XCTAssertEqual(i?.notesZh, "中")
        XCTAssertNil(LuckgramUpdateLogic.deserialize("{not json"))
        XCTAssertNil(LuckgramUpdateLogic.deserialize(""))
        let empty = LuckgramUpdateLogic.parse([:])
        XCTAssertEqual(empty?.latest, "")
        XCTAssertEqual(empty?.build, 0)
    }
    func testNewFieldsAndGuide() throws {
        let sha = String(repeating: "Ab", count: 32)
        let data = ("{\"latest\":\"13.1.2\",\"build\":36300,\"url\":\"https://dl.luckgram.cc/ios/x.ipa\",\"sha256\":\"" + sha + "\",\"size\":123,\"install_url\":\"https://wiki.luckgram.cc/i.html\"}").data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parsed = LuckgramUpdateLogic.parse(json)
        let i = LuckgramUpdateLogic.deserialize(LuckgramUpdateLogic.serialize(parsed))
        XCTAssertEqual(i, parsed)
        XCTAssertEqual(i?.sha256, sha.lowercased())
        XCTAssertEqual(i?.size, 123)
        let state = LuckgramUpdateLogic.evaluate(i, current: "13.1.1", currentBuild: 36294, chinese: true)
        XCTAssertTrue(state.updateAvailable)
        XCTAssertEqual(state.installUrl, "https://wiki.luckgram.cc/i.html")

        // old server: no new fields, the guide link falls back to the default page
        let old = LuckgramUpdateLogic.parse(["latest": "13.1.2", "url": "https://dl.luckgram.cc/ios/x.ipa", "sha256": NSNull()])
        XCTAssertEqual(old?.sha256, "")
        XCTAssertEqual(old?.size, 0)
        XCTAssertEqual(LuckgramUpdateLogic.evaluate(old, current: "13.1.1", currentBuild: 0, chinese: false).installUrl, LuckgramUpdateLogic.defaultInstallUrl)
        XCTAssertEqual(LuckgramUpdateLogic.parse(["sha256": "abc"])?.sha256, "")
        XCTAssertEqual(LuckgramUpdateLogic.installGuideUrl("http://x"), LuckgramUpdateLogic.defaultInstallUrl)
        XCTAssertEqual(LuckgramUpdateLogic.installGuideUrl(nil), LuckgramUpdateLogic.defaultInstallUrl)

        XCTAssertEqual(LuckgramUpdateLogic.guideActions(force: false), [.download, .guide, .later])
        XCTAssertEqual(LuckgramUpdateLogic.guideActions(force: true), [.download, .guide])
    }

    func testCheckAgainAfterTheInstalledBuildChanged() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let recent = now.addingTimeInterval(-60)
        let b36373 = LuckgramUpdateLogic.appId(version: "13.1.1", build: 36373)
        XCTAssertEqual(b36373, "13.1.1+36373")
        // checked at an older build, then a newer one was installed: ask again now
        XCTAssertTrue(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: recent, lastFailure: nil, checkedBy: LuckgramUpdateLogic.appId(version: "13.1.1", build: 36294), running: b36373))
        XCTAssertFalse(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: recent, lastFailure: nil, checkedBy: b36373, running: b36373))
        // first run after updating from a version that did not store it
        XCTAssertTrue(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: recent, lastFailure: nil, checkedBy: "", running: b36373))
        XCTAssertFalse(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: nil, lastFailure: recent, checkedBy: "", running: b36373))
        // review P3: a changed build still waits out a recent failure (no retry on every foreground)
        XCTAssertFalse(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: recent, lastFailure: recent, checkedBy: LuckgramUpdateLogic.appId(version: "13.1.1", build: 36294), running: b36373))
        XCTAssertTrue(LuckgramUpdateLogic.shouldCheck(now: now, lastSuccess: recent, lastFailure: now.addingTimeInterval(-hour), checkedBy: LuckgramUpdateLogic.appId(version: "13.1.1", build: 36294), running: b36373))
    }

    func testTextsCarryBuild() {
        let url = "https://dl.luckgram.cc/ios/ios-13.1.1-36373/Luckgram-13.1.1-36373.ipa"
        let s = LuckgramUpdateLogic.evaluate(info("13.1.1", 36373, "0", url), current: "13.1.1", currentBuild: 36294, chinese: true)
        XCTAssertTrue(s.updateAvailable)
        XCTAssertEqual(s.build, 36373)
        XCTAssertEqual(LuckgramUpdateLogic.label("13.1.1", build: 36373, chinese: true), "13.1.1（36373）")
        XCTAssertEqual(LuckgramUpdateLogic.label("13.1.1", build: 36373, chinese: false), "13.1.1 (36373)")
        XCTAssertEqual(LuckgramUpdateLogic.label("13.1.1", build: 0, chinese: true), "13.1.1")
        XCTAssertEqual(LuckgramUpdateLogic.rowText(s, chinese: true), "有新版本 13.1.1（36373） · 更新")
        XCTAssertEqual(LuckgramUpdateLogic.rowText(s, chinese: false), "New version 13.1.1 (36373) · Update")
        XCTAssertEqual(LuckgramUpdateLogic.guideTitle(s, chinese: true), "更新到 13.1.1（36373）")
        XCTAssertEqual(LuckgramUpdateLogic.guideMessage(s, chinese: true), "新版本 13.1.1（36373） 需要重新签名安装。")
        XCTAssertEqual(LuckgramUpdateLogic.forceText(s, current: "13.1.1", currentBuild: 36294, chinese: true), "当前版本 13.1.1（36294） 已停止支持，请更新到 13.1.1（36373） 后继续使用。")
        XCTAssertEqual(LuckgramUpdateLogic.forceText(s, current: "13.1.1", currentBuild: 36294, chinese: false), "Version 13.1.1 (36294) is no longer supported. Update to 13.1.1 (36373) to continue.")
        // server without build: version only
        let noBuild = LuckgramUpdateLogic.evaluate(info("13.2", 0, "0", url), current: "13.1.1", currentBuild: 36294, chinese: true)
        XCTAssertEqual(LuckgramUpdateLogic.rowText(noBuild, chinese: true), "有新版本 13.2 · 更新")
    }
}
