import Foundation
import UIKit
import TelegramCore
import AccountContext

/// What a ✦ menu item or panel can do with the message field of the open chat (spec 21 需求 6).
public protocol LuckgramAIWritingHost: AnyObject {
    var context: AccountContext { get }
    var peerId: EnginePeer.Id? { get }
    /// The chat's peer, as used by `MenuItem.isVisible`.
    var peer: EnginePeer? { get }
    var threadId: Int64? { get }
    /// True in a channel where the user can post.
    var canPostInChannel: Bool { get }
    var isChannel: Bool { get }
    var text: String { get }
    /// Replaces the field's text; with `undoable` the previous text can be restored with `undo()`.
    func setText(_ text: String, undoable: Bool)
    var canUndo: Bool { get }
    func undo()
    /// Shows `view` above the input field (one panel at a time), `height` points tall.
    func showPanel(_ view: UIView, height: CGFloat)
    /// Hides `view` if it is the panel shown.
    func hidePanel(_ view: UIView)
    /// Presents a controller (e.g. the AI consent alert or an error toast).
    func present(_ controller: UIViewController)
    /// Sends `text` to the chat the way the user would from the field (as the channel when posting
    /// in a channel); with `schedule`, Telegram's schedule picker opens first.
    func send(_ text: String, schedule: Bool)
}

/// Extension points of AI writing (spec 21 需求 6), for 20 (AI reply) and 24 (AI post). Those
/// features add one registration line in `LuckgramAIWritingFeatures.registerAll()`:
///
///     LuckgramAIWriting.register(.init(id: "reply", title: ("帮我回复", "Help me reply"), icon: "arrowshape.turn.up.left",
///         order: 0, allowsEmptyText: true, isVisible: { peer in peer != nil }) { host in
///         host.showPanel(myView, height: 160.0)
///         host.setText("…", undoable: true)
///     })
///
/// `order`: smaller first; the built-in effects use 100…140.
public enum LuckgramAIWriting {
    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiWriting)
    }

    /// spec 21 需求 4
    public static let maxChars = 4000

    public struct MenuItem {
        public let id: String
        public let title: (String, String)
        /// SF Symbol name.
        public let icon: String?
        public let order: Int
        public let allowsEmptyText: Bool
        /// Whether to show the item in this chat (e.g. only in channels where the user can post).
        public let isVisible: (EnginePeer?) -> Bool
        public let action: (LuckgramAIWritingHost) -> Void

        public init(id: String, title: (String, String), icon: String?, order: Int, allowsEmptyText: Bool = false, isVisible: @escaping (EnginePeer?) -> Bool = { _ in true }, action: @escaping (LuckgramAIWritingHost) -> Void) {
            self.id = id
            self.title = title
            self.icon = icon
            self.order = order
            self.allowsEmptyText = allowsEmptyText
            self.isVisible = isVisible
            self.action = action
        }
    }

    private static var items: [MenuItem] = []

    /// Replaces an item with the same id.
    public static func register(_ item: MenuItem) {
        self.items.removeAll(where: { $0.id == item.id })
        self.items.append(item)
    }

    public static func unregister(id: String) {
        self.items.removeAll(where: { $0.id == id })
    }

    /// Items to show for this field, sorted by order.
    public static func visibleItems(host: LuckgramAIWritingHost, hasText: Bool) -> [MenuItem] {
        return self.visibleItems(peer: host.peer, hasText: hasText)
    }

    static func visibleItems(peer: EnginePeer?, hasText: Bool) -> [MenuItem] {
        LuckgramAIWritingFeatures.registerAll()
        return self.items.filter { (hasText || $0.allowsEmptyText) && $0.isVisible(peer) }.sorted(by: { $0.order < $1.order })
    }

    /// Whether the ✦ button should show for an empty field in this chat (some item allows it).
    public static func hasItemsForEmptyText(peer: EnginePeer?) -> Bool {
        return !self.visibleItems(peer: peer, hasText: false).isEmpty
    }

    public static func isBroadcastChannel(_ peer: EnginePeer?) -> Bool {
        if case let .channel(channel) = peer, case .broadcast = channel.info {
            return true
        }
        return false
    }

    /// A channel where the user can post (spec 24 shows its item only there).
    public static func canPostInChannel(_ peer: EnginePeer?) -> Bool {
        if case let .channel(channel) = peer, case .broadcast = channel.info {
            return channel.hasPermission(.sendText)
        }
        return false
    }

    /// The ✦ menu as an action sheet.
    public static func makeMenu(host: LuckgramAIWritingHost) -> UIAlertController? {
        let items = self.visibleItems(host: host, hasText: !host.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if items.isEmpty {
            return nil
        }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for item in items {
            let action = UIAlertAction(title: LuckgramStrings.pick(item.title.0, item.title.1), style: .default) { [weak host] _ in
                if let host {
                    item.action(host)
                }
            }
            if let icon = item.icon, let image = UIImage(systemName: icon) {
                action.setValue(image, forKey: "image")
            }
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel))
        return sheet
    }
}

/// Registration of everything in the ✦ menu. Features that extend AI writing (20, 24) add one line
/// here and keep their code in their own files.
public enum LuckgramAIWritingFeatures {
    private static var registered = false

    static func registerAll() {
        if self.registered {
            return
        }
        self.registered = true

        // spec 21 需求 1: the five effects (server prompts/writing-<effect>.md)
        self.effect("polish", ("润色", "Polish"), "wand.and.stars", 100, ("已润色", "Polished"))
        self.effect("formal", ("更正式", "More formal"), "briefcase", 110, ("已改得更正式", "Made more formal"))
        self.effect("friendly", ("更友好", "Friendlier"), "face.smiling", 120, ("已改得更友好", "Made friendlier"))
        self.effect("shorter", ("更简短", "Shorter"), "text.badge.minus", 130, ("已缩短", "Shortened"))
        self.effect("grammar", ("修正语法", "Fix grammar"), "textformat.abc", 140, ("已修正语法", "Grammar fixed"))

        self.registerDebugDemo()
        // ---- other features register here (20 AI reply, 24 AI post) ----
        LuckgramAIWriting.register(LuckgramAIReply.menuItem)
    }

    private static func effect(_ effect: String, _ title: (String, String), _ icon: String, _ order: Int, _ done: (String, String)) {
        LuckgramAIWriting.register(.init(id: effect, title: title, icon: icon, order: order, action: { host in
            (host as? LuckgramAIWritingEffectRunner)?.runWritingEffect(effect, done: LuckgramStrings.pick(done.0, done.1))
        }))
    }

    /// spec 21 验收：a test item placed first and shown only in channels, opening a test panel that
    /// writes into the field with undo. Only with the debug tools on.
    private static func registerDebugDemo() {
        LuckgramAIWriting.register(.init(id: "debug_panel", title: ("测试面板", "Test panel"), icon: "ladybug", order: -1, allowsEmptyText: true, isVisible: { peer in
            return LuckgramSettings.shared.isDebugToolsVisible && LuckgramAIWriting.isBroadcastChannel(peer)
        }, action: { host in
            let panel = UIStackView()
            panel.axis = .horizontal
            panel.alignment = .center
            panel.spacing = 8.0
            panel.isLayoutMarginsRelativeArrangement = true
            panel.layoutMargins = UIEdgeInsets(top: 0.0, left: 12.0, bottom: 0.0, right: 8.0)
            let label = UILabel()
            label.text = "Debug panel"
            label.font = UIFont.systemFont(ofSize: 15.0)
            let write = UIButton(type: .system, primaryAction: UIAction(title: "写入 / Write") { [weak host] _ in
                host?.setText("Text written by the debug panel ✍️", undoable: true)
            })
            let close = UIButton(type: .system)
            close.setImage(UIImage(systemName: "xmark"), for: .normal)
            close.addAction(UIAction { [weak host, weak panel] _ in
                if let host, let panel {
                    host.hidePanel(panel)
                }
            }, for: .touchUpInside)
            panel.addArrangedSubview(label)
            panel.addArrangedSubview(UIView())
            panel.addArrangedSubview(write)
            panel.addArrangedSubview(close)
            host.showPanel(panel, height: 44.0)
        }))
    }
}

/// Implemented by the message field's host to run the built-in effects.
public protocol LuckgramAIWritingEffectRunner: AnyObject {
    func runWritingEffect(_ effect: String, done: String)
}
