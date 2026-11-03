import Foundation

/// Luckgram spec 01 「翻译服务」5: translation results keyed by (target language, text), at most
/// `maxEntries`, each kept `maxAge`. Opening the same translation again shows the cached result
/// without a request (and without spending quota). Keys are hashes, so the cache file holds only
/// translations, not the original texts. Foundation only, unit tested on Linux; same rules as
/// Android `org.telegram.luckgram.translateout.TranslateCache`.
public final class LuckgramTranslateCache {
    public static let maxEntries = 2000
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    public struct Entry: Equatable {
        public let text: String
        /// Source language, or nil when unknown.
        public let fromLang: String?
        public let time: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private let limit: Int
    private let age: TimeInterval

    public init(maxEntries: Int = LuckgramTranslateCache.maxEntries, maxAge: TimeInterval = LuckgramTranslateCache.maxAge) {
        self.limit = maxEntries
        self.age = maxAge
    }

    /// Cache key of `text` translated into `toLang` (two 64-bit FNV-1a hashes, hex).
    public static func key(toLang: String, text: String) -> String {
        let bytes = Array((toLang + "\u{0}" + text).utf8)
        func fnv(_ seed: UInt64) -> UInt64 {
            var h: UInt64 = seed
            for b in bytes {
                h ^= UInt64(b)
                h = h &* 0x100000001b3
            }
            return h
        }
        let a = fnv(0xcbf29ce484222325)
        let b = fnv(0x84222325cbf29ce4 ^ UInt64(bytes.count))
        return String(format: "%016llx%016llx", a, b)
    }

    public var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries.count
    }

    public func get(_ key: String, now: TimeInterval) -> Entry? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.entries[key] else {
            return nil
        }
        if now - entry.time > self.age {
            self.entries[key] = nil
            self.order.removeAll(where: { $0 == key })
            return nil
        }
        self.order.removeAll(where: { $0 == key })
        self.order.append(key)
        return entry
    }

    public func put(_ key: String, text: String, fromLang: String?, now: TimeInterval) {
        if text.isEmpty {
            return
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries[key] = Entry(text: text, fromLang: fromLang, time: now)
        self.order.removeAll(where: { $0 == key })
        self.order.append(key)
        while self.order.count > self.limit {
            let oldest = self.order.removeFirst()
            self.entries[oldest] = nil
        }
    }

    /// JSON array, least recently used first, so `parse` restores the same order.
    public func serialize(now: TimeInterval) -> Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        var items: [[String: Any]] = []
        for key in self.order {
            guard let e = self.entries[key], now - e.time <= self.age else {
                continue
            }
            var item: [String: Any] = ["k": key, "t": e.text, "d": e.time]
            if let f = e.fromLang {
                item["f"] = f
            }
            items.append(item)
        }
        return (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
    }

    /// Restores `serialize` output; expired or malformed entries are skipped.
    public static func parse(_ data: Data?, now: TimeInterval) -> LuckgramTranslateCache {
        let cache = LuckgramTranslateCache()
        guard let data, let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return cache
        }
        for item in items {
            guard let k = item["k"] as? String, let t = item["t"] as? String, !k.isEmpty, !t.isEmpty else {
                continue
            }
            let d = (item["d"] as? Double) ?? (item["d"] as? NSNumber)?.doubleValue ?? 0
            if now - d <= cache.age {
                cache.put(k, text: t, fromLang: item["f"] as? String, now: d)
            }
        }
        return cache
    }
}
