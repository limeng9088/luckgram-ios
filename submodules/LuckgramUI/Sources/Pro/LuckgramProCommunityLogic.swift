import Foundation

/// specs#89 (31): Pro community, the parts that need no UI: what `POST /v1/pro/community/invite` (S14)
/// answered, which links may be opened, the Bot API → Telegram channel id, and the texts.
/// Foundation only; unit-tested in `LuckgramProCommunityLogicTests`.
public enum LuckgramProCommunityLogic {
    /// Feature switch (default on).
    public static let featureKey = "pro_community"
    public static let invitePath = "/v1/pro/community/invite"
    public static let codeNotPro = "not_pro"
    public static let codeAlreadyMember = "already_member"

    public enum Invite: Equatable {
        /// Open this one-time invite link (Telegram's join sheet).
        case join(link: String)
        /// Already in the group: its channel id (0 if not sent) and an optional link to it.
        case alreadyMember(channelId: Int64, link: String?)
        case badAnswer
    }

    /// The row shows when the feature is on and the server lists the perk (29: no perk, no row).
    public static func showRow(featureEnabled: Bool, hasPerk: Bool) -> Bool {
        return featureEnabled && hasPerk
    }

    /// A 200 body: `{invite_link}` or `{already_member: true, chat_id, chat_link?}`.
    public static func parse(_ body: [String: Any]?) -> Invite {
        guard let body else {
            return .badAnswer
        }
        if (body[codeAlreadyMember] as? Bool) == true || (body["status"] as? String) == codeAlreadyMember {
            return alreadyMember(body)
        }
        if let link = firstLink(body, ["invite_link", "url", "link"]) {
            return .join(link: link)
        }
        return .badAnswer
    }

    /// `already_member` (in a 200 body, or as an error with no body).
    public static func alreadyMember(_ body: [String: Any]?) -> Invite {
        let body = body ?? [:]
        let raw: Int64
        if let n = body["chat_id"] as? NSNumber {
            raw = n.int64Value
        } else if let s = body["chat_id"] as? String, let n = Int64(s) {
            raw = n
        } else {
            raw = 0
        }
        return .alreadyMember(channelId: channelId(botApiId: raw), link: firstLink(body, ["chat_link", "invite_link", "url", "link"]))
    }

    /// Bot API supergroup id (-100…) or a plain channel id → the channel id; 0 if neither.
    public static func channelId(botApiId: Int64) -> Int64 {
        if botApiId < -1_000_000_000_000 {
            return -botApiId - 1_000_000_000_000
        }
        return botApiId > 0 ? botApiId : 0
    }

    /// Only Telegram links are opened (inside the app).
    public static func isOpenableLink(_ url: String?) -> Bool {
        guard let url else {
            return false
        }
        for prefix in ["tg://", "https://t.me/", "https://telegram.me/"] where url.hasPrefix(prefix) {
            return url.count > prefix.count
        }
        return false
    }

    private static func firstLink(_ body: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let v = body[key] as? String, isOpenableLink(v) {
                return v
            }
        }
        return nil
    }

    public struct Texts {
        let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        private func t(_ zh: String, _ en: String) -> String {
            return self.zh ? zh : en
        }

        public var join: String { return t("加入 Pro 社群", "Join the Pro community") }
        public var info: String { return t("Luckgram Pro 用户的 Telegram 私密群。会员到期后会自动移出，续期后可重新加入。",
            "A private Telegram group for Luckgram Pro members. You leave it automatically when Pro ends and can join again after renewing.") }
        public var alreadyMember: String { return t("你已经在 Pro 社群里", "You're already in the Pro community") }
        public var proOnly: String { return t("Pro 社群是 Luckgram Pro 专享，订阅后即可加入", "The Pro community is for Luckgram Pro members. Subscribe to join") }
    }
}
