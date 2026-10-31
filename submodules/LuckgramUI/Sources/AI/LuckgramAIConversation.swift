import Foundation
import SwiftSignalKit
import AccountContext

/// One local AI conversation (spec 18). Lives only on the device, never as a Telegram chat.
///
/// Extension point "conversation properties" (spec 18 需求 8): `task` and `systemPrompt` are sent
/// with every request of this conversation; `key` lets a feature find its own conversation again
/// (e.g. one per agent, spec 22) with `LuckgramAIStore.findOrCreate`.
public final class LuckgramAIConversation: Codable {
    /// Messages sent as context with each request (spec 18 需求 6).
    public static let contextMessages = 20

    public final class Message: Codable {
        public static let roleUser = "user"
        public static let roleAssistant = "assistant"
        /// Plain text (Markdown for assistant replies). Other types come from the message type registry.
        public static let typeText = "text"

        public var id: String
        public var role: String
        public var type: String
        public var text: String?
        /// Free-form payload for registered message types (e.g. an image path), JSON-compatible values.
        public var data: [String: String]?
        /// Set when the request failed: a `LuckgramAIError` code.
        public var errorCode: String?
        public var time: Double
        /// True while the reply is streaming in (not saved).
        public var isPending = false

        enum CodingKeys: String, CodingKey {
            case id, role, type, text, data, errorCode = "error", time
        }

        public init(role: String, type: String = Message.typeText, text: String?) {
            self.id = UUID().uuidString
            self.role = role
            self.type = type
            self.text = text
            self.time = Date().timeIntervalSince1970
        }

        public var isUser: Bool {
            return self.role == Message.roleUser
        }
    }

    public var id: String
    /// Optional stable key set by the feature that created it; nil for normal conversations.
    public var key: String?
    public var title: String?
    /// `task` of /v1/ai/chat.
    public var task: LuckgramAI.AITask
    /// Extra system instruction sent first with every request, or nil.
    public var systemPrompt: String?
    public var createdAt: Double
    public var updatedAt: Double
    public var messages: [Message]

    enum CodingKeys: String, CodingKey {
        case id, key, title, task, systemPrompt = "system", createdAt = "created", updatedAt = "updated", messages
    }

    init(task: LuckgramAI.AITask, systemPrompt: String?, title: String?) {
        self.id = UUID().uuidString
        self.task = task
        self.systemPrompt = systemPrompt
        self.title = title
        self.createdAt = Date().timeIntervalSince1970
        self.updatedAt = self.createdAt
        self.messages = []
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.key = try c.decodeIfPresent(String.self, forKey: .key)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.task = LuckgramAI.AITask(rawValue: (try c.decodeIfPresent(String.self, forKey: .task)) ?? "chat") ?? .chat
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.createdAt = (try c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0.0
        self.updatedAt = (try c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? self.createdAt
        self.messages = (try c.decodeIfPresent([Message].self, forKey: .messages)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.id, forKey: .id)
        try c.encodeIfPresent(self.key, forKey: .key)
        try c.encodeIfPresent(self.title, forKey: .title)
        try c.encode(self.task.rawValue, forKey: .task)
        try c.encodeIfPresent(self.systemPrompt, forKey: .systemPrompt)
        try c.encode(self.createdAt, forKey: .createdAt)
        try c.encode(self.updatedAt, forKey: .updatedAt)
        try c.encode(self.messages.filter { !$0.isPending }, forKey: .messages)
    }

    /// The request messages: the system instruction, then the last `contextMessages` messages that
    /// have text for the model (failed and pending ones are skipped), oldest dropped first if the
    /// total would go over `maxChars` (the server's ai.max_input_chars, counted in code points).
    public func requestMessages(maxChars: Int) -> [LuckgramAI.Message] {
        var picked: [LuckgramAI.Message] = []
        var chars = self.systemPrompt?.unicodeScalars.count ?? 0
        var count = 0
        for message in self.messages.reversed() {
            if count >= LuckgramAIConversation.contextMessages {
                break
            }
            if message.isPending || message.errorCode != nil {
                continue
            }
            guard var text = LuckgramAIRegistry.contextText(message), !text.isEmpty else {
                continue
            }
            let length = text.unicodeScalars.count
            if chars + length > maxChars {
                if picked.isEmpty {
                    // the newest message alone is too long: send its end, the server would reject all of it
                    var scalars = String.UnicodeScalarView()
                    scalars.append(contentsOf: text.unicodeScalars.suffix(max(0, maxChars - chars)))
                    text = String(scalars)
                } else {
                    break
                }
            }
            chars += text.unicodeScalars.count
            picked.insert(message.isUser ? .user(text) : .assistant(text), at: 0)
            count += 1
        }
        if let systemPrompt = self.systemPrompt, !systemPrompt.isEmpty {
            picked.insert(.system(systemPrompt), at: 0)
        }
        return picked
    }
}

/// Per-account local storage of AI conversations (spec 18 需求 6), in the account's own folder
/// (`<account>/luckgram-ai/conversations.json`), which Telegram deletes when the account logs out.
/// Main thread only.
public final class LuckgramAIStore {
    private static var instances: [Int64: LuckgramAIStore] = [:]

    public static func shared(context: AccountContext) -> LuckgramAIStore {
        let id = context.account.id.int64
        if let current = self.instances[id] {
            return current
        }
        let store = LuckgramAIStore(path: context.account.basePath + "/luckgram-ai")
        self.instances[id] = store
        return store
    }

    /// Called from `LuckgramSettings.accountRemoved`.
    static func accountRemoved(accountId: Int64) {
        if let store = self.instances.removeValue(forKey: accountId) {
            store.conversations.removeAll()
            store.changesPipe.putNext(Void())
            try? FileManager.default.removeItem(atPath: store.directory)
        }
    }

    private let directory: String
    private var conversations: [LuckgramAIConversation] = []
    private var loaded = false
    private var saveTimer: SwiftSignalKit.Timer?
    private let queue = Queue(name: "LuckgramAIStore")
    private let changesPipe = ValuePipe<Void>()

    /// Fires on the main thread after any change.
    public var changes: Signal<Void, NoError> {
        return self.changesPipe.signal()
    }

    private init(path: String) {
        self.directory = path
    }

    private var filePath: String {
        return self.directory + "/conversations.json"
    }

    /// Folder for files belonging to one conversation (e.g. generated images, spec 23); deleted with
    /// the conversation and, being inside the account's folder, with the account's data.
    public func conversationDirectory(_ conversationId: String) -> String {
        let path = self.directory + "/files/" + conversationId
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func ensureLoaded() {
        if self.loaded {
            return
        }
        self.loaded = true
        if let data = try? Data(contentsOf: URL(fileURLWithPath: self.filePath)),
           let list = try? JSONDecoder().decode([LuckgramAIConversation].self, from: data) {
            self.conversations = list
        }
    }

    /// Conversations, most recently used first. Ones with no messages are not listed.
    public func list() -> [LuckgramAIConversation] {
        self.ensureLoaded()
        return self.conversations.filter { !$0.messages.isEmpty }.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    public func get(_ id: String) -> LuckgramAIConversation? {
        self.ensureLoaded()
        return self.conversations.first(where: { $0.id == id })
    }

    /// A new, empty conversation (not listed until it has a message).
    public func create(task: LuckgramAI.AITask = .chat, systemPrompt: String? = nil, title: String? = nil) -> LuckgramAIConversation {
        self.ensureLoaded()
        let conversation = LuckgramAIConversation(task: task, systemPrompt: systemPrompt, title: title)
        self.conversations.append(conversation)
        return conversation
    }

    /// The conversation with this `key`, created on first use (extension point: e.g. one
    /// conversation per agent). Task and system instruction are updated if they changed.
    public func findOrCreate(key: String, task: LuckgramAI.AITask = .chat, systemPrompt: String? = nil, title: String? = nil) -> LuckgramAIConversation {
        self.ensureLoaded()
        if let current = self.conversations.first(where: { $0.key == key }) {
            var changed = false
            if current.task != task {
                current.task = task
                changed = true
            }
            if let systemPrompt, current.systemPrompt != systemPrompt {
                current.systemPrompt = systemPrompt
                changed = true
            }
            if changed {
                self.save(current)
            }
            return current
        }
        let conversation = self.create(task: task, systemPrompt: systemPrompt, title: title)
        conversation.key = key
        return conversation
    }

    /// Call after changing a conversation; writes it to disk shortly after.
    public func save(_ conversation: LuckgramAIConversation?) {
        conversation?.updatedAt = Date().timeIntervalSince1970
        self.scheduleWrite()
        self.changesPipe.putNext(Void())
    }

    public func delete(_ id: String) {
        self.ensureLoaded()
        self.conversations.removeAll(where: { $0.id == id })
        let folder = self.directory + "/files/" + id
        self.queue.async {
            try? FileManager.default.removeItem(atPath: folder)
        }
        self.scheduleWrite()
        self.changesPipe.putNext(Void())
    }

    private func scheduleWrite() {
        self.saveTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: 0.3, repeat: false, completion: { [weak self] in
            guard let self else {
                return
            }
            self.saveTimer = nil
            let toSave = self.conversations.filter { !$0.messages.isEmpty }
            guard let data = try? JSONEncoder().encode(toSave) else {
                return
            }
            let directory = self.directory
            let path = self.filePath
            self.queue.async {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }, queue: Queue.mainQueue())
        self.saveTimer = timer
        timer.start()
    }
}
