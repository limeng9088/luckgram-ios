import Foundation

/// Pure logic of the update check (task S5, luckgram-specs#30): parsing `GET /v1/version`,
/// comparing versions with the server's rule, deciding when to check and what to show.
/// Foundation only (SwiftPM unit tests); same rules as UpdateLogic.java on Android.
public enum LuckgramUpdateLogic {
    /// Check at most once an hour. Was once a day (spec: "启动时（每天最多一次）"), but releases now
    /// ship several times a day with the same version name and only a new build, so a day-old answer
    /// hid newer builds. Same TTL as the remote config; the request is a few hundred bytes.
    public static let checkInterval: TimeInterval = 60 * 60
    /// After a failed check try again on a later launch, but not more often than this.
    public static let retryAfterFailure: TimeInterval = 60 * 60

    /// What `GET /v1/version` said, persisted so the hint survives restarts.
    public struct Info: Equatable {
        public var latest: String
        public var build: Int64
        public var min: String
        public var url: String
        public var notesZh: String
        public var notesEn: String
        /// specs#123/#124: install guide (iOS), package SHA-256 and size; empty / 0 until the server sends them.
        public var installUrl: String
        public var sha256: String
        public var size: Int64

        public init(latest: String, build: Int64, min: String, url: String, notesZh: String, notesEn: String, installUrl: String = "", sha256: String = "", size: Int64 = 0) {
            self.latest = latest
            self.build = build
            self.min = min
            self.url = url
            self.notesZh = notesZh
            self.notesEn = notesEn
            self.installUrl = installUrl
            self.sha256 = sha256
            self.size = size
        }
    }

    /// What the app shows.
    public struct State: Equatable {
        /// "有新版本 x.y.z · 更新" on top of Settings.
        public var updateAvailable: Bool
        /// Full-screen "must update" with only the Update button.
        public var forceUpdate: Bool
        public var latest: String
        public var url: String
        public var notes: String
        /// Install guide, always an https link (server value or the default guide).
        public var installUrl: String = LuckgramUpdateLogic.defaultInstallUrl
        /// Build of `latest` (0 = unknown), shown next to the version: releases often keep the version.
        public var build: Int64 = 0

        public static let hidden = State(updateAvailable: false, forceUpdate: false, latest: "", url: "", notes: "")
    }

    /// specs#123: used while the server does not send `install_url` yet.
    public static let defaultInstallUrl = "https://wiki.luckgram.cc/getting-started/install.html"

    public static func installGuideUrl(_ value: String?) -> String {
        if let value, value.lowercased().hasPrefix("https://"), value.count > 8 {
            return value
        }
        return defaultInstallUrl
    }

    /// The guide sheet (specs#124): "下载安装包", "查看安装指南", and "以后再说" unless updating is forced.
    public enum GuideAction: Equatable {
        case download
        case guide
        case later
    }

    public static func guideActions(force: Bool) -> [GuideAction] {
        return force ? [.download, .guide] : [.download, .guide, .later]
    }

    /// "13.1.1+36373": identifies the installed app for `shouldCheck`.
    public static func appId(version: String, build: Int64) -> String {
        return "\(version)+\(max(0, build))"
    }

    /// `checkedBy` is the `appId` of the app that made the last successful check ("" = unknown),
    /// `running` the one of the running app. Another app than the one that checked last (an update
    /// was installed, or an older build) checks right away: the cached answer was judged against
    /// another build.
    public static func shouldCheck(now: Date, lastSuccess: Date?, lastFailure: Date?, checkedBy: String = "", running: String = "") -> Bool {
        if lastSuccess != nil, !running.isEmpty, running != checkedBy {
            return true
        }
        if let lastFailure, now >= lastFailure, now.timeIntervalSince(lastFailure) < retryAfterFailure {
            return false
        }
        guard let lastSuccess else {
            return true
        }
        // now < lastSuccess: the clock went back; check rather than wait for a day that may never come
        return now < lastSuccess || now.timeIntervalSince(lastSuccess) >= checkInterval
    }

    /// Dotted numbers only, 1–4 segments (same as the server and the X-Luckgram-App-Version guard).
    public static func isVersion(_ v: String?) -> Bool {
        guard let v else {
            return false
        }
        return v.range(of: #"^\d{1,9}(\.\d{1,9}){0,3}$"#, options: .regularExpression) != nil
    }

    /// `/v1/version?platform=ios&app_version=..[&build=..]`; build 0 = unknown.
    public static func path(platform: String, appVersion: String?, build: Int64) -> String {
        var s = "/v1/version?platform=\(platform)"
        if let appVersion, isVersion(appVersion) {
            s += "&app_version=\(appVersion)"
            if build > 0 {
                s += "&build=\(build)"
            }
        }
        return s
    }

    /// Server rule: dotted numbers compared segment by segment, a missing segment counts as 0.
    /// Anything that is not a version compares as 0.0.0.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = isVersion(a) ? a.split(separator: ".").map { Int64($0) ?? 0 } : []
        let y = isVersion(b) ? b.split(separator: ".").map { Int64($0) ?? 0 } : []
        for i in 0 ..< max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q {
                return p < q ? -1 : 1
            }
        }
        return 0
    }

    /// Equal versions with both builds known compare by build.
    public static func isNewer(latest: String, latestBuild: Int64, current: String, currentBuild: Int64) -> Bool {
        let c = compareVersions(latest, current)
        if c != 0 {
            return c > 0
        }
        return latestBuild > 0 && currentBuild > 0 && latestBuild > currentBuild
    }

    public static func parse(_ json: [String: Any]?) -> Info? {
        guard let json else {
            return nil
        }
        let notes = json["notes"] as? [String: Any]
        let build: Int64
        if let n = json["build"] as? NSNumber {
            build = n.int64Value
        } else {
            build = 0
        }
        let size: Int64
        if let n = json["size"] as? NSNumber {
            size = max(0, n.int64Value)
        } else {
            size = 0
        }
        var sha256 = (json["sha256"] as? String ?? "").lowercased()
        if sha256.count != 64 || !sha256.allSatisfy({ $0.isHexDigit }) {
            sha256 = ""
        }
        return Info(
            latest: json["latest"] as? String ?? "",
            build: build,
            min: json["min"] as? String ?? "",
            url: json["url"] as? String ?? "",
            notesZh: notes?["zh"] as? String ?? "",
            notesEn: notes?["en"] as? String ?? "",
            installUrl: json["install_url"] as? String ?? "",
            sha256: sha256,
            size: size
        )
    }

    public static func serialize(_ info: Info?) -> String {
        guard let info else {
            return ""
        }
        let object: [String: Any] = [
            "latest": info.latest, "build": NSNumber(value: info.build), "min": info.min, "url": info.url,
            "notes": ["zh": info.notesZh, "en": info.notesEn],
            "install_url": info.installUrl, "sha256": info.sha256, "size": NSNumber(value: info.size)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object), let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }

    public static func deserialize(_ s: String?) -> Info? {
        guard let s, !s.isEmpty, let data = s.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parse(json)
    }

    /// Evaluated against the running version every time (not the server's update_available), so a
    /// cached answer stops nagging as soon as the user has installed the new version. Nothing is
    /// shown without an https download link: a "must update" screen without a way to update would
    /// lock the user out.
    public static func evaluate(_ info: Info?, current: String, currentBuild: Int64, chinese: Bool) -> State {
        guard let info, info.url.hasPrefix("https://"), isVersion(current) else {
            return .hidden
        }
        let force = isVersion(info.min) && compareVersions(current, info.min) < 0
        let available = isVersion(info.latest) && isNewer(latest: info.latest, latestBuild: info.build, current: current, currentBuild: currentBuild)
        if !force && !available {
            return .hidden
        }
        let notes = chinese ? (info.notesZh.isEmpty ? info.notesEn : info.notesZh) : (info.notesEn.isEmpty ? info.notesZh : info.notesEn)
        // Below min but latest not newer (misconfigured): still force, the link is the way out.
        let latestIsTarget = isVersion(info.latest) && (available || compareVersions(info.latest, info.min) >= 0)
        return State(updateAvailable: true, forceUpdate: force, latest: isVersion(info.latest) ? info.latest : info.min, url: info.url, notes: notes, installUrl: installGuideUrl(info.installUrl), build: latestIsTarget ? info.build : 0)
    }

    // MARK: - texts (same as UpdateDownloadLogic.Texts on Android)

    /// "13.1.1（36373）" / "13.1.1 (36373)"; only the version while the build is unknown (0).
    public static func label(_ version: String, build: Int64, chinese: Bool) -> String {
        guard build > 0 else {
            return version
        }
        return chinese ? "\(version)（\(build)）" : "\(version) (\(build))"
    }

    /// Settings row: "有新版本 13.1.1（36373） · 更新".
    public static func rowText(_ state: State, chinese: Bool) -> String {
        let l = label(state.latest, build: state.build, chinese: chinese)
        return chinese ? "有新版本 \(l) · 更新" : "New version \(l) · Update"
    }

    /// Guide sheet title: "更新到 13.1.1（36373）".
    public static func guideTitle(_ state: State, chinese: Bool) -> String {
        let l = label(state.latest, build: state.build, chinese: chinese)
        return chinese ? "更新到 \(l)" : "Update to \(l)"
    }

    /// Guide sheet text: "新版本 13.1.1（36373） 需要重新签名安装。".
    public static func guideMessage(_ state: State, chinese: Bool) -> String {
        let l = label(state.latest, build: state.build, chinese: chinese)
        return chinese ? "新版本 \(l) 需要重新签名安装。" : "Version \(l) has to be re-signed and installed."
    }

    /// Force page: installed version and the one to update to, both with their builds.
    public static func forceText(_ state: State, current: String, currentBuild: Int64, chinese: Bool) -> String {
        let c = label(current, build: currentBuild, chinese: chinese)
        let l = label(state.latest, build: state.build, chinese: chinese)
        return chinese ? "当前版本 \(c) 已停止支持，请更新到 \(l) 后继续使用。" : "Version \(c) is no longer supported. Update to \(l) to continue."
    }
}
