import Foundation
import UIKit

/// Debug demos of the five extension points (spec 18 验收：用调试代码各演示一次). Only shown / active
/// when the debug tools are visible (`LuckgramSettings.shared.isDebugToolsVisible`):
/// 1. quick button "测试按钮" → an alert;
/// 2. input interceptor `/echo text` → replies "echo: text" without any request;
/// 3. header entry "测试对话" → opens the conversation with key `debug_demo`;
/// 4. that conversation has a system instruction ("answer in one sentence") sent with every request;
/// 5. message type `debug_card`: `/card text` adds one; `/unknown` adds an unregistered type to show the placeholder.
enum LuckgramAIDebugDemo {
    static let cardType = "debug_card"

    static func register() {
        let visible: () -> Bool = { LuckgramSettings.shared.isDebugToolsVisible }
        LuckgramAIRegistry.registerQuickAction(.init(id: "debug_button", title: ("测试按钮", "Test button"), icon: "ladybug", isVisible: visible, action: { host in
            let alert = UIAlertController(title: nil, message: "Quick action: " + host.conversation.id, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            host.viewController.present(alert, animated: true)
        }))
        LuckgramAIRegistry.registerInputInterceptor(prefixes: ["/echo", "/card", "/unknown"], handler: { host, prefix, rest in
            if !visible() {
                return false
            }
            host.addMessage(LuckgramAIConversation.Message(role: LuckgramAIConversation.Message.roleUser, text: prefix + " " + rest))
            let reply: LuckgramAIConversation.Message
            switch prefix {
            case "/echo":
                reply = LuckgramAIConversation.Message(role: LuckgramAIConversation.Message.roleAssistant, text: "echo: " + rest)
            case "/card":
                reply = LuckgramAIConversation.Message(role: LuckgramAIConversation.Message.roleAssistant, type: cardType, text: rest)
                reply.data = ["created": String(Int(Date().timeIntervalSince1970))]
            default:
                reply = LuckgramAIConversation.Message(role: LuckgramAIConversation.Message.roleAssistant, type: "debug_not_registered", text: rest)
            }
            host.addMessage(reply)
            return true
        })
        LuckgramAIRegistry.registerHeaderEntry(.init(id: "debug_conversation", title: ("测试对话", "Test chat"), icon: "text.bubble", isVisible: visible, action: { host in
            let conversation = LuckgramAIStore.shared(context: host.context).findOrCreate(key: "debug_demo", task: .chat, systemPrompt: "Always answer in exactly one sentence.", title: "测试对话 / Test chat")
            LuckgramAIChatController.open(context: host.context, conversationId: conversation.id, from: host)
        }))
        LuckgramAIRegistry.registerMessageType(cardType, renderer: CardRenderer())
    }

    private final class CardRenderer: LuckgramAIMessageRenderer {
        private let font = UIFont.systemFont(ofSize: 15.0)

        private func text(_ message: LuckgramAIConversation.Message) -> String {
            return "🧪 debug_card\n" + (message.text ?? "")
        }

        func makeView() -> UIView {
            let label = UILabel()
            label.numberOfLines = 0
            label.font = self.font
            label.textColor = .white
            label.backgroundColor = .systemPurple
            label.layer.cornerRadius = 10.0
            label.clipsToBounds = true
            label.textAlignment = .center
            return label
        }

        func update(view: UIView, message: LuckgramAIConversation.Message, isOutgoing: Bool, maxWidth: CGFloat) {
            (view as? UILabel)?.text = self.text(message)
        }

        func size(message: LuckgramAIConversation.Message, maxWidth: CGFloat) -> CGSize {
            let bounds = (self.text(message) as NSString).boundingRect(with: CGSize(width: maxWidth - 20.0, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: self.font], context: nil)
            return CGSize(width: min(maxWidth, ceil(bounds.width) + 20.0), height: ceil(bounds.height) + 16.0)
        }

        func contextText(_ message: LuckgramAIConversation.Message) -> String? {
            return nil // not sent to the model
        }
    }
}
