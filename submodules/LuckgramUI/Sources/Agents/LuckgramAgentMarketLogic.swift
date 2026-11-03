import Foundation

/// specs#88 (30): the AI agent market without UI dependencies (Foundation only, tested with SwiftPM
/// on Linux). Parses the S13 responses, builds request paths, keeps the local cache and the "used"
/// list. Same behavior as Android `AgentMarketLogic`.
///
/// The server never sends an agent's system instruction; nothing here stores one.
public enum LuckgramAgentMarketLogic {
    /// Page size of `GET /v1/agents` (server allows 1...50).
    public static let pageSize = 20
    /// Most agents kept in the "used" list ("我的").
    public static let maxUsed = 50
    /// Most agent details kept in the cache.
    public static let maxCachedDetails = 100
    /// Key prefix of the AI assistant conversation of a market agent (spec 18 extension point 4).
    public static let conversationKeyPrefix = "market:"
    /// Request field of /v1/ai/chat task=agent naming the market agent (S13).
    public static let paramAgentId = "agent_id"
    public static let errorNotPro = "not_pro"
    public static let errorAgentUnavailable = "agent_unavailable"
    /// Avatar color when the server gives none (or an invalid one).
    public static let defaultColor: UInt32 = 0x5B8DEF
    public static let categoriesPath = "/v1/agents/categories"

    // MARK: - Model

    /// A string in both app languages.
    public struct Text: Codable, Equatable {
        public var zh: String
        public var en: String

        public init(zh: String, en: String) {
            self.zh = zh
            self.en = en
        }

        public func pick(chinese: Bool) -> String {
            let s = chinese ? self.zh : self.en
            return s.isEmpty ? (chinese ? self.en : self.zh) : s
        }

        static func parse(_ value: Any?) -> Text {
            if let o = value as? [String: Any] {
                return Text(zh: (o["zh"] as? String) ?? "", en: (o["en"] as? String) ?? "")
            }
            if let s = value as? String {
                return Text(zh: s, en: s)
            }
            return Text(zh: "", en: "")
        }

        func contains(_ lowerQuery: String) -> Bool {
            return self.zh.lowercased().contains(lowerQuery) || self.en.lowercased().contains(lowerQuery)
        }
    }

    public struct Agent: Codable, Equatable {
        public var id: String
        public var name = Text(zh: "", en: "")
        public var description = Text(zh: "", en: "")
        public var category = ""
        public var color: UInt32 = LuckgramAgentMarketLogic.defaultColor
        public var emoji = ""
        public var imageUrl = ""
        public var examples: [Text] = []
        public var author = "luckgram"
        public var proOnly = false
        public var modelTier = "standard"
        public var users: Int64 = 0

        public init(id: String) {
            self.id = id
        }

        public var isPremium: Bool {
            return self.modelTier == "premium"
        }

        /// What the round avatar shows: the emoji, else the first character of the name.
        public func avatarText(chinese: Bool) -> String {
            if !self.emoji.isEmpty {
                return self.emoji
            }
            let n = self.name.pick(chinese: chinese).trimmingCharacters(in: .whitespaces)
            return n.first.map { String($0).uppercased() } ?? "?"
        }

        public func matches(_ query: String?) -> Bool {
            let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return q.isEmpty || self.name.contains(q) || self.description.contains(q)
        }
    }

    public struct Category: Codable, Equatable {
        public var id: String
        public var name: Text
        public var count: Int
    }

    public struct Page: Codable, Equatable {
        public var items: [Agent]
        /// nil on the last page.
        public var nextCursor: String?
    }

    // MARK: - Parsing

    /// One agent of `/v1/agents` or `/v1/agents/{id}`; nil without an id.
    public static func parseAgent(_ value: Any?) -> Agent? {
        guard let o = value as? [String: Any], let id = o["id"] as? String, !id.isEmpty else {
            return nil
        }
        var a = Agent(id: id)
        a.name = Text.parse(o["name"])
        a.description = Text.parse(o["description"])
        a.category = (o["category"] as? String) ?? ""
        if let avatar = o["avatar"] as? [String: Any] {
            a.color = self.parseColor(avatar["color"] as? String) ?? self.defaultColor
            a.emoji = (avatar["emoji"] as? String) ?? ""
            let url = (avatar["image_url"] as? String) ?? ""
            a.imageUrl = url.hasPrefix("https://") ? url : ""
        }
        if let examples = o["examples"] as? [Any] {
            a.examples = examples.map { Text.parse($0) }.filter { !$0.zh.isEmpty || !$0.en.isEmpty }
        }
        a.author = (o["author"] as? String) ?? "luckgram"
        a.proOnly = (o["pro_only"] as? Bool) ?? false
        a.modelTier = (o["model_tier"] as? String) ?? "standard"
        a.users = max(0, self.int64(o["users"]))
        // never keep an instruction, even if a server ever sent one
        return a
    }

    /// `{"items":[…],"next_cursor":…|null}`
    public static func parsePage(_ object: [String: Any]?) -> Page {
        let items = ((object?["items"] as? [Any]) ?? []).compactMap { self.parseAgent($0) }
        let next = (object?["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Page(items: items, nextCursor: next)
    }

    /// `{"categories":[{id,name{zh,en},count}]}`, in the server's order.
    public static func parseCategories(_ object: [String: Any]?) -> [Category] {
        return ((object?["categories"] as? [Any]) ?? []).compactMap { value in
            guard let c = value as? [String: Any], let id = c["id"] as? String, !id.isEmpty else {
                return nil
            }
            return Category(id: id, name: Text.parse(c["name"]), count: Int(self.int64(c["count"])))
        }
    }

    static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let v as Int:
            return Int64(v)
        case let v as Int64:
            return v
        case let v as Double:
            return Int64(v)
        case let v as NSNumber:
            return v.int64Value
        default:
            return 0
        }
    }

    /// `#RRGGBB` → RGB, or nil.
    public static func parseColor(_ s: String?) -> UInt32? {
        guard let s, s.count == 7, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else {
            return nil
        }
        return v
    }

    // MARK: - Requests

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func encode(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: self.queryAllowed) ?? s
    }

    /// `/v1/agents?limit=&category=&q=&cursor=`; empty values are left out.
    public static func listPath(category: String?, query: String?, cursor: String?, limit: Int) -> String {
        var path = "/v1/agents?limit=\(limit)"
        if let category, !category.isEmpty {
            path += "&category=" + self.encode(category)
        }
        var q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            // the server accepts at most 50 characters (code points)
            if q.unicodeScalars.count > 50 {
                var scalars = String.UnicodeScalarView()
                scalars.append(contentsOf: q.unicodeScalars.prefix(50))
                q = String(scalars)
            }
            path += "&q=" + self.encode(q)
        }
        if let cursor, !cursor.isEmpty {
            path += "&cursor=" + self.encode(cursor)
        }
        return path
    }

    public static func detailPath(_ id: String) -> String {
        return "/v1/agents/" + self.encode(id)
    }

    /// Extra fields of `POST /v1/ai/chat` for a market agent (task=agent).
    public static func chatParams(agentId: String) -> [String: String] {
        return [self.paramAgentId: agentId]
    }

    public static func conversationKey(_ agentId: String) -> String {
        return self.conversationKeyPrefix + agentId
    }

    /// spec 30 需求 5: a free user can see a Pro agent but has to upgrade to chat.
    public static func needsUpgrade(_ agent: Agent?, isPro: Bool) -> Bool {
        return (agent?.proOnly ?? false) && !isPro
    }

    /// "1.2万人使用" / "1.2K users" (same as Android).
    public static func formatUsers(_ users: Int64, chinese: Bool) -> String {
        func trim(_ v: Double) -> String {
            let s = String(format: "%.1f", (v * 10.0).rounded(.down) / 10.0)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        if chinese {
            let n: String
            if users >= 100_000_000 {
                n = trim(Double(users) / 100_000_000.0) + "亿"
            } else if users >= 10_000 {
                n = trim(Double(users) / 10_000.0) + "万"
            } else {
                n = "\(users)"
            }
            return n + "人使用"
        }
        let n: String
        if users >= 1_000_000 {
            n = trim(Double(users) / 1_000_000.0) + "M"
        } else if users >= 1_000 {
            n = trim(Double(users) / 1_000.0) + "K"
        } else {
            n = "\(users)"
        }
        return n + (users == 1 ? " user" : " users")
    }

    // MARK: - Cache (spec 30 需求 7)

    /// Categories, the first page of each list ("" = all) and details. Search results are not
    /// cached; offline, search filters the cached agents.
    public struct Cache: Codable, Equatable {
        public var categories: [Category] = []
        public var lists: [String: Page] = [:]
        public var details: [String: Agent] = [:]
        public var detailOrder: [String] = []

        public init() {
        }

        public static func decode(_ stored: String?) -> Cache {
            guard let data = stored?.data(using: .utf8), let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
                return Cache()
            }
            return cache
        }

        public func encoded() -> String? {
            return (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }

        public mutating func putFirstPage(category: String?, _ page: Page) {
            self.lists[category ?? ""] = page
        }

        public func firstPage(category: String?) -> Page? {
            return self.lists[category ?? ""]
        }

        public mutating func putDetail(_ agent: Agent) {
            self.details[agent.id] = agent
            self.detailOrder.removeAll(where: { $0 == agent.id })
            self.detailOrder.append(agent.id)
            while self.detailOrder.count > LuckgramAgentMarketLogic.maxCachedDetails {
                self.details.removeValue(forKey: self.detailOrder.removeFirst())
            }
        }

        /// Every cached agent (lists, then details), each once, for offline search.
        public func allAgents() -> [Agent] {
            var out: [Agent] = []
            var seen = Set<String>()
            for key in self.lists.keys.sorted() {
                for a in self.lists[key]?.items ?? [] where !seen.contains(a.id) {
                    seen.insert(a.id)
                    out.append(a)
                }
            }
            for id in self.detailOrder {
                if let a = self.details[id], !seen.contains(a.id) {
                    seen.insert(a.id)
                    out.append(a)
                }
            }
            return out
        }

        /// Offline list: cached agents of `category` ("" = all) matching `query`.
        public func offline(category: String?, query: String?) -> [Agent] {
            let plain = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if plain, let page = self.firstPage(category: category) {
                return page.items
            }
            let all = (category ?? "").isEmpty
            return self.allAgents().filter { (all || $0.category == category) && $0.matches(query) }
        }

        public func detail(_ id: String) -> Agent? {
            return self.details[id] ?? self.allAgents().first(where: { $0.id == id })
        }
    }

    // MARK: - Used agents (spec 30 需求 6)

    public static func decodeUsed(_ stored: String?) -> [Agent] {
        guard let data = stored?.data(using: .utf8), let list = try? JSONDecoder().decode([Agent].self, from: data) else {
            return []
        }
        return list
    }

    public static func encodeUsed(_ used: [Agent]) -> String? {
        return (try? JSONEncoder().encode(used)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Puts `agent` first (replacing an older snapshot), keeping at most `maxUsed`.
    public static func markUsed(_ used: [Agent], _ agent: Agent) -> [Agent] {
        return Array(([agent] + used.filter { $0.id != agent.id }).prefix(self.maxUsed))
    }

    /// Replaces the snapshot of an agent already in the list, keeping its place.
    public static func refreshUsed(_ used: [Agent], _ agent: Agent) -> [Agent] {
        return used.map { $0.id == agent.id ? agent : $0 }
    }

    public static func removeUsed(_ used: [Agent], id: String) -> [Agent] {
        return used.filter { $0.id != id }
    }
}
