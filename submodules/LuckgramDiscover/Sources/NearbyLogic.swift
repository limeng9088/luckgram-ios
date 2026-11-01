import Foundation

/// Pure logic of "People Nearby" (spec 25, server S10): coordinate coarsening, response parsing,
/// distance-bucket grouping, expiry / reminder times, preconditions and all texts in both
/// languages. Same rules as `org.telegram.luckgram.nearby.NearbyLogic` on Android.
public enum NearbyLogic {
    public static let featureKey = "nearby"
    public static let bioMax = 70
    public static let maxResults = 100
    /// Reminder this long before the visibility expires (spec 25 item 4).
    public static let remindBefore: TimeInterval = 60 * 60
    public static let defaultVisible: TimeInterval = 24 * 60 * 60
    /// Avatar upload limit agreed with S10: base64 JPEG ≤ 256 KB.
    public static let avatarMaxBytes = 256 * 1024

    // MARK: - coordinates

    /// Rounds a coordinate to a ~1 km grid (2 decimals). The raw value never leaves the device.
    public static func coarsen(_ value: Double) -> Double {
        if value.isNaN || value.isInfinite {
            return 0
        }
        return (value * 100).rounded() / 100
    }

    /// Coarsened coordinate as sent: 2 decimals, "." separator.
    public static func coord(_ value: Double) -> String {
        let s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), coarsen(value))
        return s == "-0.00" ? "0.00" : s
    }

    public static func isValidLocation(lat: Double, lon: Double) -> Bool {
        return !lat.isNaN && !lon.isNaN && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    }

    public static func queryPath(lat: Double, lon: Double) -> String {
        return "/v1/nearby?lat=\(coord(lat))&lon=\(coord(lon))"
    }

    // MARK: - card

    /// Trims the bio and cuts it to `bioMax` characters.
    public static func cleanBio(_ bio: String?) -> String {
        guard let bio else {
            return ""
        }
        var s = bio.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > bioMax {
            s = String(s.prefix(bioMax))
        }
        return s
    }

    /// `avatarBase64`: nil = leave the server's avatar as is, "" = delete it.
    public static func cardBody(displayName: String, bio: String, username: String, lat: Double, lon: Double, avatarBase64: String?) -> [String: Any] {
        var body: [String: Any] = [
            "display_name": displayName,
            "bio": cleanBio(bio),
            "username": username,
            // Decimal keeps exactly 2 decimals in the JSON (a Double may print as 31.230000000000001).
            "lat": Decimal(string: coord(lat)) ?? 0,
            "lon": Decimal(string: coord(lon)) ?? 0
        ]
        if let avatarBase64 {
            body["avatar"] = avatarBase64
        }
        return body
    }

    // MARK: - preconditions

    public enum Precondition: Equatable {
        case ready
        case needUsername
    }

    /// Only the public username is up to the user; the S6 link is made silently (spec 25 item 2).
    public static func precondition(username: String?) -> Precondition {
        if username?.isEmpty ?? true {
            return .needUsername
        }
        return .ready
    }

    // MARK: - responses

    public struct Person: Equatable {
        public var id: String
        public var displayName: String
        public var bio: String
        public var username: String
        public var avatarUrl: String?
        public var bucket: String

        public init(id: String, displayName: String, bio: String, username: String, avatarUrl: String?, bucket: String) {
            self.id = id
            self.displayName = displayName
            self.bio = bio
            self.username = username
            self.avatarUrl = avatarUrl
            self.bucket = bucket
        }
    }

    public struct MyState: Equatable {
        public var visible: Bool
        public var expiresAt: Date?
    }

    public static func parseMe(_ j: [String: Any], now: Date = Date()) -> MyState {
        let visible = j["visible"] as? Bool ?? false
        var expires = (j["expires_at"] as? String).flatMap(parseTime)
        if visible && expires == nil {
            expires = now.addingTimeInterval(defaultVisible)
        }
        return MyState(visible: visible, expiresAt: visible ? expires : nil)
    }

    /// Parses `GET /v1/nearby`; drops entries without id/username and the user's own card.
    public static func parseList(_ j: [String: Any], selfUsername: String?) -> [Person] {
        guard let items = j["items"] as? [[String: Any]] else {
            return []
        }
        var out: [Person] = []
        for o in items {
            if out.count >= maxResults {
                break
            }
            let id = o["id"] as? String ?? ""
            let username = o["username"] as? String ?? ""
            if id.isEmpty || username.isEmpty {
                continue
            }
            if let selfUsername, username.lowercased() == selfUsername.lowercased() {
                continue
            }
            var name = o["display_name"] as? String ?? ""
            if name.isEmpty {
                name = username
            }
            var avatar = o["avatar_url"] as? String
            if let a = avatar, !a.hasPrefix("https://") {
                avatar = nil
            }
            out.append(Person(id: id, displayName: name, bio: o["bio"] as? String ?? "", username: username, avatarUrl: avatar, bucket: normalizeBucket(o["distance_bucket"] as? String)))
        }
        return out
    }

    public static let buckets = ["500m", "1km", "3km", "10km", "far"]

    public static func normalizeBucket(_ b: String?) -> String {
        if let b, buckets.contains(b) {
            return b
        }
        return "far"
    }

    /// Groups by bucket in `buckets` order (empty groups left out); order inside a group is the server's (random).
    public static func group(_ people: [Person]) -> [(bucket: String, people: [Person])] {
        var out: [(bucket: String, people: [Person])] = []
        for b in buckets {
            let l = people.filter { $0.bucket == b }
            if !l.isEmpty {
                out.append((b, l))
            }
        }
        return out
    }

    // MARK: - expiry

    /// When to show the "expires in 1 hour" reminder, or nil if it is already too late.
    /// Oldest location fix accepted (CLLocationManager may hand back a cached one).
    public static let fixMaxAge: TimeInterval = 30 * 60

    public static func isFreshFix(_ fixTime: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(fixTime)
        return age <= fixMaxAge && age >= -60
    }

    public static func reminderAt(expiresAt: Date, now: Date) -> Date? {
        let at = expiresAt.addingTimeInterval(-remindBefore)
        return at > now ? at : nil
    }

    public static func isExpired(_ expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else {
            return true
        }
        return now >= expiresAt
    }

    public static func parseTime(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) {
            return d
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - report

    public static let reportReasons = ["spam", "scam", "porn", "impersonation", "other"]

    public static func reportBody(user: String, reason: String) -> [String: Any] {
        return ["user": user, "reason": reason]
    }

    // MARK: - texts

    public struct Texts {
        let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        private func t(_ zhText: String, _ enText: String) -> String {
            return zh ? zhText : enText
        }

        public var title: String { t("附近的人", "People Nearby") }

        public var needUsernameTitle: String { t("需要先设置用户名", "Set a username first") }
        public var needUsernameText: String { t("别人通过你的公开用户名打开和你的私聊。设置用户名后再回来。", "Others open a chat with you through your public username. Set one, then come back.") }
        public var goUsername: String { t("去设置用户名", "Set username") }

        public var introTitle: String { t("开始前请了解", "Before you start") }
        public var introText: String {
            t("• 打开「在附近可见」后，会上传你的名片（显示名、头像、简介、用户名）和模糊位置（约 1 公里网格，原始坐标不离开手机）。\n"
                + "• 只有同样打开的 Luckgram 用户能看到你，看到的是距离档位，不是位置。\n"
                + "• 24 小时后自动关闭，到期前 1 小时提醒你续期。\n"
                + "• 随时可以关闭；关闭或退出登录后，名片会立即从服务端删除。\n"
                + "• 只在打开页面、刷新、续期时定位一次，不会后台定位。\n"
                + "• 浏览列表时（包括关闭可见时）也会用同样的模糊位置向服务端查询；为防止定位追踪，服务端会短期保留你上次查询所在的约 1 公里网格，但不保存名片。",
              "• When \"Visible nearby\" is on, your card (name, photo, bio, username) and a blurred location (about a 1 km grid; the exact position never leaves your phone) are uploaded.\n"
                + "• Only Luckgram users who also turned it on can see you, and they see a distance range, not a location.\n"
                + "• It turns off after 24 hours; you get a reminder 1 hour before so you can renew.\n"
                + "• Turn it off at any time. Turning it off or logging out deletes your card from the server right away.\n"
                + "• Your location is read once when you open this page, refresh or renew, never in the background.\n"
                + "• Browsing the list (also while not visible) sends the same blurred location to the server to find people; to prevent location tracking the server briefly keeps the ~1 km grid cell of your last search, but no card.")
        }
        public var introContinue: String { t("我知道了，继续", "Got it, continue") }

        public var noPermission: String { t("没有定位权限，无法显示附近的人。可以在系统设置里允许 Luckgram 使用位置。", "No location permission, so nobody can be shown. Allow Luckgram to use your location in system settings.") }
        public var openSettings: String { t("打开系统设置", "Open settings") }
        public var locationFailed: String { t("暂时无法获取位置，请点「刷新」重试", "Couldn't get your location. Tap Refresh to try again.") }
        public var locationOff: String { t("系统定位已关闭，请先打开定位服务", "Location services are off. Turn them on first.") }

        public var visibleSwitch: String { t("在附近可见", "Visible nearby") }
        public var visibleOffInfo: String { t("关闭时只浏览：会用模糊位置查询附近的人，但不上传名片，别人看不到你。", "While off you only browse: a blurred location is used to search, but your card isn't uploaded and nobody can see you.") }
        public func visibleUntil(_ time: String) -> String { t("可见到 \(time)，到期前 1 小时提醒你续期。", "Visible until \(time). You'll be reminded 1 hour before.") }
        public var renew: String { t("续期 24 小时", "Renew for 24 hours") }
        public var renewed: String { t("已续期 24 小时", "Renewed for 24 hours") }
        public var myCard: String { t("我的名片", "My card") }
        public var bio: String { t("一句话简介", "Bio") }
        public var bioHint: String { t("介绍一下自己（最多 70 字）", "Say something about yourself (up to 70 characters)") }
        public var bioEmpty: String { t("未填写", "Not set") }
        public var showPhoto: String { t("显示头像", "Show photo") }
        public var save: String { t("保存", "Save") }

        public var empty: String { t("附近暂时没有打开可见的人，稍后刷新试试。", "Nobody nearby has turned it on yet. Try refreshing later.") }
        public var loading: String { t("正在查找附近的人…", "Looking for people nearby…") }
        public var refresh: String { t("刷新", "Refresh") }

        public func bucket(_ b: String) -> String {
            switch b {
            case "500m": return t("500 米内", "Within 500 m")
            case "1km": return t("1 公里内", "Within 1 km")
            case "3km": return t("3 公里内", "Within 3 km")
            case "10km": return t("10 公里内", "Within 10 km")
            default: return t("更远", "Farther")
            }
        }

        public var sendMessage: String { t("发消息", "Send message") }
        public var report: String { t("举报", "Report") }
        public var hide: String { t("不再显示此人", "Don't show this person") }
        public func hideConfirm(_ name: String) -> String { t("不再显示后，你和 \(name) 在「附近的人」和「广场」里互相看不到对方。", "You and \(name) will no longer see each other in People Nearby and Square.") }
        public var hidden: String { t("已不再显示此人", "You won't see this person again") }
        public var reportTitle: String { t("举报原因", "Reason") }
        public func reportReason(_ r: String) -> String {
            switch r {
            case "spam": return t("垃圾信息", "Spam")
            case "scam": return t("诈骗", "Scam")
            case "porn": return t("色情", "Pornography")
            case "impersonation": return t("冒充他人", "Impersonation")
            default: return t("其他", "Other")
            }
        }
        public var reported: String { t("已举报，感谢反馈", "Reported. Thank you.") }
        public var cancel: String { t("取消", "Cancel") }

        public var reminderTitle: String { t("「在附近可见」1 小时后关闭", "\"Visible nearby\" turns off in 1 hour") }
        public var reminderText: String { t("打开「附近的人」续期，继续让附近的人看到你。", "Open People Nearby to renew and stay visible.") }

        public func rateLimited(_ seconds: Int) -> String {
            let min = max(1, (seconds + 59) / 60)
            return t("操作太频繁，请 \(min) 分钟后再试", "Too many requests. Try again in \(min) min.")
        }
        public var disabled: String { t("附近的人暂时不可用，请稍后再试", "People Nearby is temporarily unavailable. Please try again later.") }
        public var underReview: String { t("你的名片被举报，正在审核，暂时不会出现在附近的人里", "Your card was reported and is under review. It won't appear nearby for now.") }
        public var connecting: String { t("正在连接附近的人服务…", "Connecting to People Nearby…") }
        public var connectFailed: String { t("暂时无法连接附近的人服务，请稍后再试", "People Nearby isn't reachable right now. Please try again later.") }
        public var banned: String { t("你的账号已被限制使用附近的人", "Your account can't use People Nearby") }
    }
}
