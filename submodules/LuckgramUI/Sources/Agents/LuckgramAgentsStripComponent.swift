import Foundation
import UIKit
import ComponentFlow
import TelegramPresentationData

/// spec 22 需求 5: agents added to the chat list, shown like contacts at the top of the chat list
/// (local only). Tapping one opens its conversation.
public final class LuckgramAgentsStripComponent: Component {
    let agents: [LuckgramAgents.Agent]
    let theme: PresentationTheme
    let open: (LuckgramAgents.Agent) -> Void

    public init(agents: [LuckgramAgents.Agent], theme: PresentationTheme, open: @escaping (LuckgramAgents.Agent) -> Void) {
        self.agents = agents
        self.theme = theme
        self.open = open
    }

    public static func ==(lhs: LuckgramAgentsStripComponent, rhs: LuckgramAgentsStripComponent) -> Bool {
        return lhs.agents == rhs.agents && lhs.theme === rhs.theme
    }

    public final class View: UIScrollView {
        private var component: LuckgramAgentsStripComponent?
        private var items: [UIButton] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.showsHorizontalScrollIndicator = false
            self.alwaysBounceHorizontal = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func itemPressed(_ sender: UIButton) {
            guard let component = self.component, sender.tag < component.agents.count else {
                return
            }
            component.open(component.agents[sender.tag])
        }

        func update(component: LuckgramAgentsStripComponent, availableSize: CGSize) -> CGSize {
            self.component = component
            let itemWidth: CGFloat = 72.0
            let height: CGFloat = 84.0
            while self.items.count < component.agents.count {
                let button = UIButton(type: .custom)
                button.tag = self.items.count
                button.addTarget(self, action: #selector(self.itemPressed(_:)), for: .touchUpInside)
                self.addSubview(button)
                self.items.append(button)
            }
            for (i, button) in self.items.enumerated() {
                guard i < component.agents.count else {
                    button.isHidden = true
                    continue
                }
                let agent = component.agents[i]
                button.isHidden = false
                var config = UIButton.Configuration.plain()
                config.image = LuckgramAgents.avatarImage(agent, size: 48.0)
                config.imagePlacement = .top
                config.imagePadding = 4.0
                config.title = agent.name
                config.titleLineBreakMode = .byTruncatingTail
                config.baseForegroundColor = component.theme.list.itemPrimaryTextColor
                config.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 2.0, bottom: 4.0, trailing: 2.0)
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes
                    attributes.font = UIFont.systemFont(ofSize: 12.0)
                    return attributes
                }
                button.configuration = config
                button.accessibilityLabel = agent.name
                button.frame = CGRect(x: 8.0 + CGFloat(i) * itemWidth, y: 2.0, width: itemWidth, height: height - 4.0)
            }
            self.contentSize = CGSize(width: 16.0 + CGFloat(component.agents.count) * itemWidth, height: height)
            return CGSize(width: availableSize.width, height: height)
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize)
    }
}
