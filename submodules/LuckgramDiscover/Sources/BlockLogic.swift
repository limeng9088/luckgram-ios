import Foundation

/// Pure helpers for the block list shared by People Nearby (25 / S10) and Square (26 / S11).
/// Ids are the opaque server user ids (nearby `items[].id` == square `author.id`). The server only
/// returns ids, so the name seen when blocking is cached locally. Same rules as
/// `org.telegram.luckgram.discover.BlockLogic` on Android.
public enum BlockLogic {
    public static let path = "/v1/blocks"

    private static let component: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    private static func escape(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: component) ?? s
    }

    /// `GET /v1/blocks?cursor=` — cursor is opaque, nil for the first page.
    public static func listPath(cursor: String?) -> String {
        guard let cursor, !cursor.isEmpty else {
            return path
        }
        return path + "?cursor=" + escape(cursor)
    }

    public static func deletePath(_ userId: String) -> String {
        return path + "/" + escape(userId)
    }

    public static func blockBody(_ userId: String) -> [String: Any] {
        return ["user": userId]
    }

    /// `{items:[{user}]}` — `user` is an id string (an `{id}` object is tolerated).
    public static func parseIds(_ json: [String: Any]?) -> [String] {
        var out: [String] = []
        for item in (json?["items"] as? [[String: Any]]) ?? [] {
            var id = ""
            if let u = item["user"] as? [String: Any] {
                id = (u["id"] as? String) ?? ""
            } else if let u = item["user"] as? String {
                id = u
            }
            if !id.isEmpty && !out.contains(id) {
                out.append(id)
            }
        }
        return out
    }

    public static func nextCursor(_ json: [String: Any]?) -> String? {
        guard let c = json?["next_cursor"] as? String, !c.isEmpty else {
            return nil
        }
        return c
    }

    public static func putName(_ cache: [String: String], id: String, name: String?) -> [String: String] {
        var c = cache
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        c[id] = n.isEmpty ? nil : n
        return c
    }

    public struct Texts {
        let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        private func t(_ zhText: String, _ enText: String) -> String {
            return zh ? zhText : enText
        }

        public var title: String { t("已拉黑的人", "Blocked People") }
        public var info: String { t("拉黑后，你和对方在「附近的人」和「广场」里互相看不到。这里的拉黑和 Telegram 的拉黑互不影响。", "You and the people you block can't see each other in People Nearby and Square. This is separate from blocking on Telegram.") }
        public var empty: String { t("你还没有拉黑任何人", "You haven't blocked anyone") }
        public var unknownUser: String { t("Luckgram 用户", "Luckgram user") }
        public var unblock: String { t("取消拉黑", "Unblock") }
        public func unblockConfirm(_ name: String) -> String { t("取消拉黑 \(name)？之后你们可能会在「附近的人」和「广场」里再次看到对方。", "Unblock \(name)? You may see each other again in People Nearby and Square.") }
        public var unblocked: String { t("已取消拉黑", "Unblocked") }
        public var loading: String { t("加载中…", "Loading…") }
        public var loadMore: String { t("加载更多", "Load more") }
        public var retry: String { t("重试", "Retry") }
        public var cancel: String { t("取消", "Cancel") }
        public var connectFailed: String { t("暂时无法连接服务，请稍后再试", "The service isn't reachable right now. Please try again later.") }
    }
}
