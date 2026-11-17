import Foundation

/// specs#98: after a new login, offer the "Luckgram picks" chat folder once per Telegram account.
/// Pure logic, unit-tested in LuckgramFolderOfferLogicTests.
public enum LuckgramFolderOfferLogic {
    /// Remote config keys (luckgram-server).
    public static let enabledKey = "onboarding.folder_enabled"
    public static let linkKey = "onboarding.folder_link"

    /// The slug of a https://t.me/addlist/<slug> link, nil for anything else.
    public static func slug(_ link: String?) -> String? {
        guard let link = link?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        let prefix = "https://t.me/addlist/"
        guard link.hasPrefix(prefix) else {
            return nil
        }
        let slug = String(link.dropFirst(prefix.count))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard (4 ... 64).contains(slug.count), slug.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return slug
    }

    /// Settings key remembering that this Telegram user saw the offer.
    public static func seenKey(userId: Int64) -> String {
        return "onboarding_folder_seen_\(userId)"
    }

    /// Whether to ask Telegram about the folder at all: switched on, a valid link, not seen yet.
    public static func shouldCheck(enabled: Bool, link: String?, seen: Bool, userId: Int64) -> Bool {
        return enabled && !seen && userId != 0 && slug(link) != nil
    }

    /// After checking the link: offer only when the folder is not on this account yet and has chats.
    public static func shouldOffer(alreadyAdded: Bool, peers: Int) -> Bool {
        return !alreadyAdded && peers > 0
    }

    public struct Texts {
        public let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        public var title: String { self.zh ? "Luckgram 为你精选" : "Hand-picked for you by Luckgram" }
        public var subtitle: String {
            self.zh ? "一个文件夹收好官方频道和精选内容，更新和活动不错过。" : "Official channels and picks in one folder, so you never miss an update or event."
        }
        public var add: String { self.zh ? "添加 Luckgram 精选" : "Add Luckgram Picks" }
        public var skip: String { self.zh ? "不用了" : "No thanks" }
    }
}
