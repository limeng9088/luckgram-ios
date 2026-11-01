import Foundation

/// Pure logic of the update check (task S5, luckgram-specs#30): parsing `GET /v1/version`,
/// comparing versions with the server's rule, deciding when to check and what to show.
/// Foundation only (SwiftPM unit tests); same rules as UpdateLogic.java on Android.
public enum LuckgramUpdateLogic {
    /// Check at most once a day (spec: "启动时（每天最多一次）").
    public static let checkInterval: TimeInterval = 24 * 60 * 60
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

        public init(latest: String, build: Int64, min: String, url: String, notesZh: String, notesEn: String) {
            self.latest = latest
            self.build = build
            self.min = min
            self.url = url
            self.notesZh = notesZh
            self.notesEn = notesEn
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

        public static let hidden = State(updateAvailable: false, forceUpdate: false, latest: "", url: "", notes: "")
    }

    public static func shouldCheck(now: Date, lastSuccess: Date?, lastFailure: Date?) -> Bool {
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
        return Info(
            latest: json["latest"] as? String ?? "",
            build: build,
            min: json["min"] as? String ?? "",
            url: json["url"] as? String ?? "",
            notesZh: notes?["zh"] as? String ?? "",
            notesEn: notes?["en"] as? String ?? ""
        )
    }

    public static func serialize(_ info: Info?) -> String {
        guard let info else {
            return ""
        }
        let object: [String: Any] = [
            "latest": info.latest, "build": NSNumber(value: info.build), "min": info.min, "url": info.url,
            "notes": ["zh": info.notesZh, "en": info.notesEn]
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
        return State(updateAvailable: true, forceUpdate: force, latest: isVersion(info.latest) ? info.latest : info.min, url: info.url, notes: notes)
    }
}
