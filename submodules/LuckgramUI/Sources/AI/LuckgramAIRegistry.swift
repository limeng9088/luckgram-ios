import Foundation
import UIKit
import AccountContext

/// What an extension can do with the open assistant page.
public protocol LuckgramAIChatHost: AnyObject {
    var context: AccountContext { get }
    var conversation: LuckgramAIConversation { get }
    var viewController: UIViewController { get }
    var inputText: String { get set }
    /// Appends a message to the conversation, shows it and saves.
    func addMessage(_ message: LuckgramAIConversation.Message)
    /// Shows the changes to a message already in the conversation and saves.
    func updateMessage(_ message: LuckgramAIConversation.Message)
}

/// Extension points of the AI assistant (spec 18 需求 8). Other features (22 agents, 23 images)
/// register here once at startup and never change the assistant's own code. Main thread only.
///
/// 1. Quick buttons above the input field:
///
///        LuckgramAIRegistry.registerQuickAction(.init(id: "image", title: ("画图", "Draw"), icon: "paintbrush") { host in
///            host.inputText = "画 "
///        })
///
/// 2. Input interceptors take over messages starting with a prefix (case-insensitive):
///
///        LuckgramAIRegistry.registerInputInterceptor(prefixes: ["画", "/image"]) { host, prefix, rest in
///            host.addMessage(.init(role: LuckgramAIConversation.Message.roleUser, text: prefix + rest))
///            ...
///            return true // handled; false = send to the model as usual
///        }
///
/// 3. Entries at the top of the assistant page:
///
///        LuckgramAIRegistry.registerHeaderEntry(.init(id: "agents", title: ("智能体", "Agents"), icon: "person.2") { page in ... })
///
/// 4. Conversation properties: `LuckgramAIConversation.task` / `.systemPrompt`,
///    `LuckgramAIStore.findOrCreate(key:...)` and `LuckgramAIChatController.open(context:conversationId:)`.
///
/// 5. Message types, stored in `Message.type` / `Message.data`; unregistered types show a placeholder:
///
///        LuckgramAIRegistry.registerMessageType("image", renderer: MyImageRenderer())
public enum LuckgramAIRegistry {
    public struct QuickAction {
        public let id: String
        public let title: (String, String)
        /// SF Symbol name, or nil for text only.
        public let icon: String?
        public let isVisible: () -> Bool
        public let action: (LuckgramAIChatHost) -> Void

        public init(id: String, title: (String, String), icon: String? = nil, isVisible: @escaping () -> Bool = { true }, action: @escaping (LuckgramAIChatHost) -> Void) {
            self.id = id
            self.title = title
            self.icon = icon
            self.isVisible = isVisible
            self.action = action
        }
    }

    public struct HeaderEntry {
        public let id: String
        public let title: (String, String)
        public let icon: String?
        public let isVisible: () -> Bool
        /// Gets the assistant page, e.g. to push or present another screen.
        public let action: (LuckgramAIChatHost) -> Void

        public init(id: String, title: (String, String), icon: String? = nil, isVisible: @escaping () -> Bool = { true }, action: @escaping (LuckgramAIChatHost) -> Void) {
            self.id = id
            self.title = title
            self.icon = icon
            self.isVisible = isVisible
            self.action = action
        }
    }

    /// Returns true if handled (nothing is sent to the model). `rest` is the text after the prefix, trimmed.
    public typealias InputInterceptor = (_ host: LuckgramAIChatHost, _ prefix: String, _ rest: String) -> Bool

    private struct Interceptor {
        let id: Int
        let prefixes: [String]
        let handler: InputInterceptor
    }

    private static var quickActionList: [QuickAction] = []
    private static var interceptors: [Interceptor] = []
    private static var headerEntryList: [HeaderEntry] = []
    private static var renderers: [String: LuckgramAIMessageRenderer] = [:]
    private static var nextInterceptorId = 0
    private static var didRegisterBuiltIns = false

    static let builtInPrefixes: [(String, String)] = [
        ("总结一下：", "Summarize this: "),
        ("改写一下：", "Rewrite this: "),
        ("讲解一下：", "Explain this: "),
        ("解这道题：", "Solve this: ")
    ]

    /// spec 18 需求 3: built-in quick buttons fill a prompt prefix into the input field.
    static func registerBuiltInsIfNeeded() {
        if self.didRegisterBuiltIns {
            return
        }
        self.didRegisterBuiltIns = true
        let titles: [(String, String)] = [("总结", "Summarize"), ("改写", "Rewrite"), ("讲解", "Explain"), ("解题", "Solve")]
        let ids = ["summary", "rewrite", "explain", "solve"]
        for i in 0 ..< ids.count {
            let prefix = self.builtInPrefixes[i]
            self.quickActionList.insert(QuickAction(id: ids[i], title: titles[i], action: { host in
                fillPrefix(host, LuckgramStrings.pick(prefix.0, prefix.1))
            }), at: i)
        }
        LuckgramAIDebugDemo.register()
        // ---- features that extend the assistant register here ----
        LuckgramAgents.register() // 22 agents
        LuckgramAIImage.register() // 23 images
    }

    /// Puts `prefix` in front of what is already typed (replacing another built-in prefix).
    static func fillPrefix(_ host: LuckgramAIChatHost, _ prefix: String) {
        var current = host.inputText
        for (zh, en) in self.builtInPrefixes {
            if current.hasPrefix(zh) {
                current = String(current.dropFirst(zh.count))
                break
            }
            if current.hasPrefix(en) {
                current = String(current.dropFirst(en.count))
                break
            }
        }
        host.inputText = prefix + current
    }

    /// Replaces an action with the same id.
    public static func registerQuickAction(_ action: QuickAction) {
        self.registerBuiltInsIfNeeded()
        self.quickActionList.removeAll(where: { $0.id == action.id })
        self.quickActionList.append(action)
    }

    public static func unregisterQuickAction(id: String) {
        self.quickActionList.removeAll(where: { $0.id == id })
    }

    /// Visible quick actions, in registration order.
    public static var quickActions: [QuickAction] {
        self.registerBuiltInsIfNeeded()
        return self.quickActionList.filter { $0.isVisible() }
    }

    /// Returns a token for `unregisterInputInterceptor`.
    @discardableResult
    public static func registerInputInterceptor(prefixes: [String], handler: @escaping InputInterceptor) -> Int {
        self.registerBuiltInsIfNeeded()
        self.nextInterceptorId += 1
        self.interceptors.append(Interceptor(id: self.nextInterceptorId, prefixes: prefixes, handler: handler))
        return self.nextInterceptorId
    }

    public static func unregisterInputInterceptor(_ token: Int) {
        self.interceptors.removeAll(where: { $0.id == token })
    }

    /// Runs the first interceptor whose prefix matches; true if it handled the text.
    static func intercept(host: LuckgramAIChatHost, text: String) -> Bool {
        self.registerBuiltInsIfNeeded()
        let lower = text.lowercased()
        for interceptor in self.interceptors {
            for prefix in interceptor.prefixes where lower.hasPrefix(prefix.lowercased()) {
                let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if interceptor.handler(host, prefix, rest) {
                    return true
                }
            }
        }
        return false
    }

    public static func registerHeaderEntry(_ entry: HeaderEntry) {
        self.registerBuiltInsIfNeeded()
        self.headerEntryList.removeAll(where: { $0.id == entry.id })
        self.headerEntryList.append(entry)
    }

    public static func unregisterHeaderEntry(id: String) {
        self.headerEntryList.removeAll(where: { $0.id == id })
    }

    /// Visible header entries, in registration order.
    public static var headerEntries: [HeaderEntry] {
        self.registerBuiltInsIfNeeded()
        return self.headerEntryList.filter { $0.isVisible() }
    }

    public static func registerMessageType(_ type: String, renderer: LuckgramAIMessageRenderer) {
        self.registerBuiltInsIfNeeded()
        self.renderers[type] = renderer
    }

    public static func renderer(for type: String) -> LuckgramAIMessageRenderer? {
        self.registerBuiltInsIfNeeded()
        return self.renderers[type]
    }

    /// Context text for the model: text messages as they are, others via their renderer (none if unregistered).
    static func contextText(_ message: LuckgramAIConversation.Message) -> String? {
        if message.type == LuckgramAIConversation.Message.typeText {
            return message.text
        }
        return self.renderer(for: message.type)?.contextText(message)
    }
}

/// Extension point 5: renders a registered message type inside the standard bubble.
public protocol LuckgramAIMessageRenderer: AnyObject {
    func makeView() -> UIView
    /// Fills `view` (from `makeView`) for `message`; `maxWidth` is the bubble's content width limit.
    func update(view: UIView, message: LuckgramAIConversation.Message, isOutgoing: Bool, maxWidth: CGFloat)
    /// The content size for `message` within `maxWidth`.
    func size(message: LuckgramAIConversation.Message, maxWidth: CGFloat) -> CGSize
    /// Text sent to the model as context for this message, or nil to leave it out.
    func contextText(_ message: LuckgramAIConversation.Message) -> String?
    /// Text copied by "Copy" in the long-press menu, or nil to hide it.
    func copyText(_ message: LuckgramAIConversation.Message) -> String?
}

public extension LuckgramAIMessageRenderer {
    func contextText(_ message: LuckgramAIConversation.Message) -> String? {
        return message.text
    }

    func copyText(_ message: LuckgramAIConversation.Message) -> String? {
        return message.text
    }
}
