import Foundation

/// Pure logic of the Account (S6) and Luckgram Pro (S7) pages: response parsing, polling rule,
/// dates and texts in both languages. Foundation only (unit-tested with SwiftPM); the same rules
/// are in AccountLogic.java on Android.
public enum LuckgramAccountLogic {
    /// Poll `GET /v1/link?nonce=` this often after opening the bot (luckgram-specs#31 item 3).
    public static let pollInterval: Double = 2.0
    /// After opening an invoice, refresh the membership this often, this many times.
    public static let proRefreshInterval: Double = 3.0
    public static let proRefreshTimes = 20

    /// JSON numbers: NSNumber from JSONSerialization, Int / Double in tests.
    static func int(_ v: Any?) -> Int {
        if let i = v as? Int {
            return i
        }
        if let d = v as? Double {
            return Int(d)
        }
        if let n = v as? NSNumber {
            return n.intValue
        }
        return 0
    }

    public struct LinkStatus: Equatable {
        public var linked = false
        public var devices = 0
        public var maxDevices = 0
        /// pending / linked / expired / used / limit_reached, or nil without a nonce.
        public var request: String?
    }

    public static func parseLink(_ j: [String: Any]) -> LinkStatus {
        var s = LinkStatus()
        s.linked = j["linked"] as? Bool ?? false
        s.devices = int(j["devices"])
        s.maxDevices = int(j["max_devices"])
        s.request = j["request"] as? String
        return s
    }

    public struct LinkStart: Equatable {
        public var nonce = ""
        public var url = ""
        public var expiresAt: Date?
    }

    public static func parseStart(_ j: [String: Any]) -> LinkStart {
        return LinkStart(nonce: j["nonce"] as? String ?? "", url: j["url"] as? String ?? "", expiresAt: parseTime(j["expires_at"] as? String))
    }

    /// Keep polling while the request is pending and the nonce has not expired.
    public static func shouldPoll(request: String?, now: Date, expiresAt: Date) -> Bool {
        return (request == nil || request == "pending") && now < expiresAt
    }

    /// Only links the bot itself opens: https://t.me/...
    public static func isTelegramLink(_ url: String) -> Bool {
        return url.hasPrefix("https://t.me/") && url.count > "https://t.me/".count
    }

    public struct Plan: Equatable {
        public var id: String
        public var days: Int
        public var stars: Int
    }

    public struct Billing: Equatable {
        public var enabled = false
        public var linked = false
        public var pro = false
        public var proExpiresAt: String?
        public var plans: [Plan] = []
    }

    public static func parseBilling(_ j: [String: Any]) -> Billing {
        var b = Billing()
        b.enabled = j["enabled"] as? Bool ?? false
        b.linked = j["linked"] as? Bool ?? false
        b.pro = (j["tier"] as? String) == "pro"
        b.proExpiresAt = j["pro_expires_at"] as? String
        for p in j["plans"] as? [[String: Any]] ?? [] {
            let stars = int(p["stars"])
            if stars <= 0 {
                continue
            }
            b.plans.append(Plan(id: p["id"] as? String ?? "", days: int(p["days"]), stars: stars))
        }
        return b
    }

    public static func parseTime(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else {
            return nil
        }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) {
            return d
        }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// yyyy-MM-dd in `timeZone`.
    public static func date(_ s: String?, timeZone: TimeZone = .current) -> String {
        guard let d = parseTime(s) else {
            return ""
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public struct Texts {
        let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        private func t(_ c: String, _ e: String) -> String { zh ? c : e }

        public var accountTitle: String { t("账号", "Account") }
        public var telegramAccount: String { t("Telegram 账号", "Telegram account") }
        public var linked: String { t("已绑定", "Linked") }
        public var notLinked: String { t("未绑定", "Not linked") }
        public func devices(_ n: Int, _ max: Int) -> String { t("已绑定设备：\(n) / \(max)", "Linked devices: \(n) / \(max)") }
        public var link: String { t("绑定 Telegram 账号", "Link Telegram account") }
        public var unlink: String { t("解绑", "Unlink") }
        public var waiting: String { t("等待 Bot 确认…（在 Bot 里点「开始」）", "Waiting for the bot… (tap Start in the bot)") }
        public var linkInfo: String {
            t("绑定后，同一个 Telegram 账号下的设备共享 AI 额度和 Luckgram Pro。服务器只保存 Telegram 用户 ID，不保存手机号、用户名或聊天内容。",
              "Devices linked to the same Telegram account share AI limits and Luckgram Pro. The server keeps only your Telegram user ID — no phone number, username or chats.")
        }
        public var unlinkConfirmTitle: String { t("解绑这台设备？", "Unlink this device?") }
        public var unlinkConfirmText: String {
            t("解绑后这台设备不再共享 Luckgram Pro。今天已用的 AI 额度不会因此恢复。",
              "This device will no longer share Luckgram Pro. AI usage already counted today is not reset.")
        }
        public var linkedNow: String { t("已绑定 Telegram 账号", "Telegram account linked") }
        public var unlinkedNow: String { t("已解绑", "Unlinked") }
        public func linkResult(_ request: String?, max: Int) -> String {
            switch request {
            case "expired":
                return t("绑定链接已过期，请重新点「绑定 Telegram 账号」。", "The link expired. Tap “Link Telegram account” again.")
            case "used":
                return t("这个绑定链接已被使用，请重新点「绑定 Telegram 账号」。", "This link was already used. Tap “Link Telegram account” again.")
            case "limit_reached":
                return t("这个 Telegram 账号已绑定 \(max) 台设备，请先在 Bot 里用 /devices 解绑一台。", "This Telegram account already has \(max) linked devices. Unlink one in the bot with /devices first.")
            default:
                return t("没有完成绑定，请重试。", "Linking was not completed. Please try again.")
            }
        }

        public var proTitle: String { "Luckgram Pro" }
        public var free: String { t("免费版", "Free") }
        public func proUntil(_ date: String) -> String { t("Pro，到期 \(date)", "Pro until \(date)") }
        public func plan(_ p: Plan) -> String { t("\(p.days) 天", "\(p.days) days") }
        public func stars(_ n: Int) -> String { "\(n) ⭐" }
        public var proInfo: String {
            t("用 Telegram Stars 付款，所有绑定这个 Telegram 账号的设备共享。已是 Pro 时再买会从当前到期时间往后延。",
              "Paid with Telegram Stars and shared by every device linked to this Telegram account. Buying again while Pro extends from the current end date.")
        }
        public var linkFirst: String { t("先绑定 Telegram 账号才能购买", "Link your Telegram account first") }
        public var goLink: String { t("去绑定", "Link") }
        public var notOnSale: String { t("Luckgram Pro 暂不开放购买", "Luckgram Pro is not on sale right now") }
        public var checking: String { t("正在确认付款…", "Checking the payment…") }
        public var proActive: String { t("Luckgram Pro 已生效", "Luckgram Pro is active") }

        /// Server error codes of /v1/link* and /v1/billing/*.
        public func error(_ code: String?) -> String {
            switch code ?? "" {
            case "link_unavailable", "billing_unavailable":
                return t("服务暂不可用，请稍后再试", "Not available right now. Please try again later")
            case "already_linked":
                return t("这台设备已经绑定了", "This device is already linked")
            case "not_linked":
                return self.linkFirst
            case "billing_disabled":
                return self.notOnSale
            case "rate_limited":
                return t("操作太频繁，请稍后再试", "Too many attempts. Please try again later")
            case "network_error":
                return t("网络不可用，请检查网络后重试", "No connection. Check your network and try again")
            default:
                return t("出错了，请稍后再试", "Something went wrong. Please try again later")
            }
        }
    }
}
