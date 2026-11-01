// Luckgram — activity in shared groups on user profiles (spec 16).
//
// Foundation-only rules, so they run as SwiftPM tests on Linux. Same rules as Android
// `SharedActivityLogic`.

import Foundation

public enum LuckgramSharedActivityLogic {
    /// Messages taken from each common group (messages.search, from_id = the user).
    public static let perGroup = 20
    /// At most this many messages are shown.
    public static let maxItems = 100
    /// At most this many search requests run at the same time.
    public static let maxParallel = 3
    /// Results are reused for this long; Refresh reloads.
    public static let cacheSeconds: Double = 10 * 60
    /// The whole load (groups in common + searches, including TelegramCore's FLOOD_WAIT retries)
    /// gets this long; after it, whatever has arrived is shown, marked partial, instead of a
    /// loading state that never ends (16 P1). Same as Android `TIME_BUDGET_MS`.
    public static let timeBudget: Double = 15

    /// Seconds left of the budget for a step starting now (never below a short minimum, so a
    /// late batch still gets one quick try).
    public static func remaining(startedAt: Double, now: Double) -> Double {
        return max(0.5, timeBudget - (now - startedAt))
    }

    /// Merges the per-group lists newest first (ties: higher id first), keeping at most `limit`.
    public static func newestFirst<T>(_ perGroup: [[T]], limit: Int, date: (T) -> Int32, id: (T) -> Int64) -> [T] {
        var all: [T] = []
        for list in perGroup {
            all.append(contentsOf: list)
        }
        all.sort(by: { lhs, rhs in
            let l = date(lhs)
            let r = date(rhs)
            if l != r {
                return l > r
            }
            return id(lhs) > id(rhs)
        })
        if all.count > limit {
            return Array(all.prefix(limit))
        }
        return all
    }

    public static func isFresh(loadedAt: Double, now: Double) -> Bool {
        return loadedAt > 0 && now >= loadedAt && now - loadedAt < cacheSeconds
    }

    /// Header: "最近消息 · 3 个共同群组" / "Recent messages · 3 groups in common".
    public static func header(groupCount: Int, chinese: Bool) -> String {
        if chinese {
            return "最近消息 · \(groupCount) 个共同群组"
        }
        return "Recent messages · \(groupCount) \(groupCount == 1 ? "group" : "groups") in common"
    }

    /// Header when some groups didn't answer within the time budget.
    public static func header(groupCount: Int, partial: Bool, chinese: Bool) -> String {
        let h = header(groupCount: groupCount, chinese: chinese)
        if !partial {
            return h
        }
        return h + (chinese ? "（部分群组未加载完，点「刷新」重试）" : " (some groups didn't load, tap Refresh to retry)")
    }
}
