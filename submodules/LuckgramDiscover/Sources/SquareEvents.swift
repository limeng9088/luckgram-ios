import Foundation

/// luckgram-specs#115: Square behavior events for the recommended feed. Foundation only (SwiftPM
/// tests on Linux); same rules as Android `SquareEvents`.
///
/// `Tracker` turns "which posts are on screen now" into impression / view events; `Queue` batches
/// them for `POST /v1/square/events` (contract: specs#115, w-1138). Events carry only a type, the
/// post id, the tab, the list position, a dwell time and a timestamp — never post text. Likes,
/// comments, reports and blocks are recorded by the server.
///
///     POST /v1/square/events → 202 {"accepted":n}
///     {"events":[{"type":"impression","post_id":"…","tab":"recommend","rank":3,"at":"2026-11-04T10:00:00Z"},
///                {"type":"view","post_id":"…","tab":"recommend","dwell_ms":5400,"at":"…"}, …]}
public enum SquareEvents {
    public static let path = "/v1/square/events"

    public static let impression = "impression"
    public static let view = "view"
    public static let open = "open"
    public static let share = "share"
    public static let notInterested = "not_interested"

    public static let tabUser = "user"
    public static let tabDetail = "detail"

    /// A post left on screen (app in background, phone down) doesn't count longer than this.
    public static let maxDwellMs: Int64 = 5 * 60 * 1000
    public static let batchMax = 100
    public static let queueMax = 500
    public static let flushAt = 20
    public static let flushIntervalMs: Int64 = 30_000
    /// The server drops events older than this; so do we.
    public static let maxAgeMs: Int64 = 24 * 60 * 60 * 1000

    public struct Event: Codable, Equatable {
        public var type: String
        public var postId: String
        public var tab: String
        /// Position in the list from 0, or -1 when unknown.
        public var rank: Int
        public var dwellMs: Int64
        public var timeMs: Int64

        public init(type: String, postId: String, tab: String, rank: Int = -1, dwellMs: Int64 = 0, timeMs: Int64) {
            self.type = type
            self.postId = postId
            self.tab = tab
            self.rank = rank
            self.dwellMs = dwellMs
            self.timeMs = timeMs
        }

        public var json: [String: Any] {
            var o: [String: Any] = ["type": self.type, "post_id": self.postId]
            if !self.tab.isEmpty {
                o["tab"] = self.tab
            }
            if self.rank >= 0 {
                o["rank"] = self.rank
            }
            if self.type == SquareEvents.view {
                o["dwell_ms"] = self.dwellMs
            }
            o["at"] = SquareEvents.iso(self.timeMs)
            return o
        }
    }

    static func iso(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0))
    }

    public static func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    /// One feed list (one tab). Call `update` whenever the visible posts may have changed.
    public final class Tracker {
        public let tab: String
        private var visibleSince: [String: Int64] = [:]
        private var ranks: [String: Int] = [:]
        private var impressed = Set<String>()

        public init(tab: String) {
            self.tab = tab
        }

        /// `visible`: the posts now on screen → their list position. Returns an impression the
        /// first time a post shows in this load, a view with its dwell when a post leaves the screen.
        public func update(visible: [String: Int], now: Int64) -> [Event] {
            var out: [Event] = []
            for (id, since) in self.visibleSince.sorted(by: { $0.key < $1.key }) where visible[id] == nil {
                let dwell = min(SquareEvents.maxDwellMs, max(0, now - since))
                if dwell > 0 {
                    out.append(Event(type: SquareEvents.view, postId: id, tab: self.tab, rank: self.ranks[id] ?? -1, dwellMs: dwell, timeMs: now))
                }
                self.visibleSince.removeValue(forKey: id)
            }
            for (id, rank) in visible.sorted(by: { $0.value < $1.value }) {
                self.ranks[id] = rank
                if self.visibleSince[id] == nil {
                    self.visibleSince[id] = now
                    if self.impressed.insert(id).inserted {
                        out.append(Event(type: SquareEvents.impression, postId: id, tab: self.tab, rank: rank, timeMs: now))
                    }
                }
            }
            return out
        }

        /// The list left the screen (page closed, app in background): ends every view.
        public func hideAll(now: Int64) -> [Event] {
            return self.update(visible: [:], now: now)
        }

        public func rank(of postId: String) -> Int? {
            return self.ranks[postId]
        }
    }

    /// Events waiting to be sent, oldest first; persisted between launches.
    public final class Queue {
        public private(set) var events: [Event] = []
        private var lastFlushMs: Int64
        private var failures = 0

        public init(stored: String?, now: Int64) {
            self.lastFlushMs = now
            if let data = stored?.data(using: .utf8), let list = try? JSONDecoder().decode([Event].self, from: data) {
                self.events = list.filter { now - $0.timeMs <= SquareEvents.maxAgeMs }
            }
            self.trim()
        }

        public var count: Int {
            return self.events.count
        }

        public func add(_ list: [Event]) {
            self.events.append(contentsOf: list)
            self.trim()
        }

        private func trim() {
            if self.events.count > SquareEvents.queueMax {
                self.events.removeFirst(self.events.count - SquareEvents.queueMax)
            }
        }

        public func shouldFlush(now: Int64) -> Bool {
            return !self.events.isEmpty && (self.events.count >= SquareEvents.flushAt || now - self.lastFlushMs >= SquareEvents.flushIntervalMs)
        }

        /// The next request body and its size, or nil when empty; at most `batchMax` events.
        public func nextBatch() -> (body: [String: Any], count: Int)? {
            if self.events.isEmpty {
                return nil
            }
            let batch = self.events.prefix(SquareEvents.batchMax)
            return (["events": batch.map { $0.json }], batch.count)
        }

        public func onSent(count: Int, now: Int64) {
            self.events.removeFirst(min(count, self.events.count))
            self.failures = 0
            self.lastFlushMs = now
        }

        /// Contract: retry once, then drop silently; a batch the server can't take at all (400, or
        /// 404 before the endpoint is deployed) is dropped right away.
        public func onFailed(count: Int, httpStatus: Int, now: Int64) {
            self.failures += 1
            if self.failures >= 2 || httpStatus == 400 || httpStatus == 404 {
                self.events.removeFirst(min(count, self.events.count))
                self.failures = 0
            }
            self.lastFlushMs = now
        }

        public func encoded() -> String? {
            return (try? JSONEncoder().encode(self.events)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
