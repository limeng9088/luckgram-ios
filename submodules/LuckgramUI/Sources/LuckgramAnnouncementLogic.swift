import Foundation

/// Pure logic of the chat-list announcement banner (task S8, luckgram-specs#33): parsing
/// `GET /v1/announcements`, choosing the banner, remembering closed ones. Foundation only
/// (SwiftPM unit tests); same rules as AnnouncementLogic.java on Android.
public enum LuckgramAnnouncementLogic {
    /// Re-fetch at most this often while the app is in the foreground.
    public static let refreshInterval: TimeInterval = 30 * 60
    /// After a failed fetch wait this long before trying again.
    public static let retryAfterFailure: TimeInterval = 5 * 60
    /// How many closed announcement IDs are remembered.
    public static let maxDismissed = 50

    public struct Item: Equatable {
        public let id: String
        public let title: String
        public let body: String
        public let url: String
        public let endsAt: Date?
    }

    /// The server already filtered and sorted (highest priority first).
    public static func parse(_ response: [String: Any]) -> [Item] {
        var out: [Item] = []
        for a in response["announcements"] as? [[String: Any]] ?? [] {
            let id = a["id"] as? String ?? ""
            let title = a["title"] as? String ?? ""
            if id.isEmpty || title.isEmpty {
                continue
            }
            var url = a["url"] as? String ?? ""
            if !url.hasPrefix("https://") {
                url = ""
            }
            out.append(Item(id: id, title: title, body: a["body"] as? String ?? "", url: url, endsAt: parseTime(a["ends_at"] as? String)))
        }
        return out
    }

    /// The banner to show: the first one not closed and not yet ended, or nil.
    public static func pick(_ items: [Item], dismissed: [String], now: Date) -> Item? {
        return items.first { item in
            if dismissed.contains(item.id) {
                return false
            }
            if let end = item.endsAt, now >= end {
                return false
            }
            return true
        }
    }

    /// Adds id to the closed list (newest last), keeping at most `maxDismissed`.
    public static func dismiss(_ dismissed: [String], _ id: String) -> [String] {
        var out = dismissed.filter { $0 != id }
        out.append(id)
        if out.count > maxDismissed {
            out.removeFirst(out.count - maxDismissed)
        }
        return out
    }

    public static func shouldRefresh(now: Date, lastSuccess: Date?, lastFailure: Date?) -> Bool {
        if let f = lastFailure, now.timeIntervalSince(f) < retryAfterFailure {
            return false
        }
        guard let s = lastSuccess else {
            return true
        }
        return now.timeIntervalSince(s) >= refreshInterval
    }

    /// RFC 3339 (self-contained: the unit tests compile this file alone).
    static func parseTime(_ s: String?) -> Date? {
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

    public static func parseDismissed(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8), let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return []
        }
        return arr.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    public static func serializeDismissed(_ ids: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ids), let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }
}
