import Foundation
import UIKit
import AccountContext

/// spec 22: AI agents. Five presets (local configuration below, same as Android) and the user's own
/// agents, stored per account in LuckgramSettings (removed on logout). Each agent is one
/// conversation of the AI assistant (spec 18 extension point "conversation properties": key
/// `agent:<id>`, `task=agent` and the agent's instruction as the system message).
public enum LuckgramAgents {
    /// spec 22 需求 4
    public static let maxName = 30
    public static let maxPrompt = 4000

    /// Avatar colors offered when creating an agent (same as Android).
    static let colors: [UInt32] = [0x5B8DEF, 0x4CAF50, 0xFF9800, 0xE91E63, 0x9C27B0, 0x00ACC1, 0x795548, 0x607D8B]

    private static let customKey = "ai_agents_custom"
    private static let pinnedKey = "ai_agents_pinned"

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiAgents) && LuckgramAIChatController.isEnabled
    }

    public struct Agent: Codable, Equatable {
        public var id: String
        public var isPreset: Bool
        var nameZh: String
        var nameEn: String
        var descZh: String
        var descEn: String
        public var color: UInt32
        public var prompt: String

        public var name: String {
            return self.isPreset ? LuckgramStrings.pick(self.nameZh, self.nameEn) : self.nameZh
        }

        public var description: String {
            return self.isPreset ? LuckgramStrings.pick(self.descZh, self.descEn) : self.descZh
        }

        public var initial: String {
            let trimmed = self.name.trimmingCharacters(in: .whitespaces)
            return trimmed.first.map { String($0).uppercased() } ?? "?"
        }

        public var uiColor: UIColor {
            return UIColor(red: CGFloat((self.color >> 16) & 0xff) / 255.0, green: CGFloat((self.color >> 8) & 0xff) / 255.0, blue: CGFloat(self.color & 0xff) / 255.0, alpha: 1.0)
        }

        static func custom(name: String, description: String, prompt: String, color: UInt32, id: String = UUID().uuidString) -> Agent {
            return Agent(id: id, isPreset: false, nameZh: name, nameEn: name, descZh: description, descEn: description, color: color, prompt: prompt)
        }
    }

    /// spec 22 需求 2: the five presets (same ids, texts and colors on Android).
    public static let presets: [Agent] = [
        Agent(id: "travel", isPreset: true, nameZh: "旅行规划师", nameEn: "Travel planner", descZh: "按天安排行程、预算和交通", descEn: "Day-by-day itineraries, budgets and transport", color: 0x00ACC1,
              prompt: "You are a travel planner. Ask for missing essentials (dates, budget, interests) only when needed. Plan trips day by day with morning / afternoon / evening, rough costs, transport between places and practical tips. Keep it realistic and concise."),
        Agent(id: "copywriter", isPreset: true, nameZh: "文案写手", nameEn: "Copywriter", descZh: "广告、社媒、产品文案", descEn: "Ads, social posts and product copy", color: 0xFF9800,
              prompt: "You are a copywriter. Write punchy, clear marketing copy: headlines, social posts, product descriptions and slogans. Offer two or three variants when useful, match the requested tone and platform, and keep claims honest."),
        Agent(id: "language", isPreset: true, nameZh: "语言老师", nameEn: "Language teacher", descZh: "陪你练口语、改错、讲语法", descEn: "Practice conversation, corrections, grammar", color: 0x4CAF50,
              prompt: "You are a friendly language teacher. Practice conversation in the language the user is learning, keep sentences at their level, correct mistakes gently after each reply (show the corrected sentence and a short why), and explain grammar simply when asked."),
        Agent(id: "researcher", isPreset: true, nameZh: "研究员", nameEn: "Researcher", descZh: "整理资料、对比观点、给出处", descEn: "Organize facts, compare views, cite sources", color: 0x5B8DEF,
              prompt: "You are a careful researcher. Answer with well-organized facts, compare viewpoints, separate what is established from what is uncertain, and say where information usually comes from. Never invent sources or numbers; say when you are not sure."),
        Agent(id: "coder", isPreset: true, nameZh: "编程助手", nameEn: "Coding assistant", descZh: "写代码、找 bug、解释原理", descEn: "Write code, find bugs, explain concepts", color: 0x607D8B,
              prompt: "You are a senior software engineer. Give working, idiomatic code in fenced code blocks with the language name, explain briefly why it works, point out bugs and edge cases, and ask for the language or framework when it matters.")
    ]

    // MARK: - Custom agents

    public static func custom(accountId: Int64) -> [Agent] {
        guard let json = LuckgramSettings.shared.string(self.customKey, forAccount: accountId, default: nil), let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([Agent].self, from: data) else {
            return []
        }
        return list
    }

    private static func saveCustom(_ list: [Agent], accountId: Int64) {
        if let data = try? JSONEncoder().encode(list), let json = String(data: data, encoding: .utf8) {
            LuckgramSettings.shared.setString(self.customKey, json, forAccount: accountId)
        }
    }

    /// Adds or replaces a custom agent.
    public static func save(_ agent: Agent, accountId: Int64) {
        var list = self.custom(accountId: accountId)
        if let index = list.firstIndex(where: { $0.id == agent.id }) {
            list[index] = agent
        } else {
            list.append(agent)
        }
        self.saveCustom(list, accountId: accountId)
    }

    /// Deletes a custom agent, its conversation and its chat list entry.
    public static func delete(_ agent: Agent, context: AccountContext) {
        let accountId = context.account.id.int64
        self.saveCustom(self.custom(accountId: accountId).filter { $0.id != agent.id }, accountId: accountId)
        self.setPinned(agent.id, false, accountId: accountId)
        let store = LuckgramAIStore.shared(context: context)
        for conversation in store.list() where conversation.key == self.conversationKey(agent) {
            store.delete(conversation.id)
        }
    }

    public static func find(_ id: String, accountId: Int64) -> Agent? {
        return self.presets.first(where: { $0.id == id }) ?? self.custom(accountId: accountId).first(where: { $0.id == id })
    }

    // MARK: - Chat list (spec 22 需求 5)

    public static func pinned(accountId: Int64) -> [String] {
        guard let json = LuckgramSettings.shared.string(self.pinnedKey, forAccount: accountId, default: nil), let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }

    public static func isPinned(_ id: String, accountId: Int64) -> Bool {
        return self.pinned(accountId: accountId).contains(id)
    }

    public static func setPinned(_ id: String, _ value: Bool, accountId: Int64) {
        var list = self.pinned(accountId: accountId).filter { $0 != id }
        if value {
            list.append(id)
        }
        if let data = try? JSONEncoder().encode(list), let json = String(data: data, encoding: .utf8) {
            LuckgramSettings.shared.setString(self.pinnedKey, json, forAccount: accountId)
        }
    }

    /// Pinned agents that still exist, in pin order.
    public static func pinnedAgents(accountId: Int64) -> [Agent] {
        if !self.isEnabled {
            return []
        }
        return self.pinned(accountId: accountId).compactMap { self.find($0, accountId: accountId) }
    }

    // MARK: - Conversations

    static func conversationKey(_ agent: Agent) -> String {
        return "agent:" + agent.id
    }

    /// spec 22 需求 3: one conversation per agent, task=agent with the agent's instruction.
    public static func open(_ agent: Agent, context: AccountContext, from host: LuckgramAIChatHost?) {
        let conversation = LuckgramAIStore.shared(context: context).findOrCreate(key: self.conversationKey(agent), task: .agent, systemPrompt: agent.prompt, title: agent.name)
        conversation.title = agent.name
        LuckgramAIChatController.open(context: context, conversationId: conversation.id, from: host)
    }

    /// spec 22 平台入口提示: the one registration line, called from the AI assistant's registry.
    static func register() {
        LuckgramAIRegistry.registerHeaderEntry(.init(id: "agents", title: ("智能体", "Agents"), icon: "person.2.crop.square.stack", isVisible: { LuckgramAgents.isEnabled }, action: { host in
            let controller = LuckgramAgentsController(context: host.context, host: host)
            host.viewController.navigationController?.pushViewController(controller, animated: true)
        }))
    }

    /// A round avatar with the agent's initial in its color.
    public static func avatarImage(_ agent: Agent, size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            agent.uiColor.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0.0, y: 0.0, width: size, height: size)).fill()
            let font = UIFont.systemFont(ofSize: size * 0.45, weight: .semibold)
            let text = agent.initial as NSString
            let textSize = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: (size - textSize.width) / 2.0, y: (size - textSize.height) / 2.0), withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
    }
}
