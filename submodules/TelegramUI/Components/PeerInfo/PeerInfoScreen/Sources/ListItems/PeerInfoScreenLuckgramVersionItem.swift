import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import AccountContext

/// Luckgram 28: centered grey version line at the very bottom of Settings.
/// Tap copies it; long press opens the debug page (internal builds only, decided by the caller).
final class PeerInfoScreenLuckgramVersionItem: PeerInfoScreenItem {
    let id: AnyHashable
    let text: String
    let action: () -> Void
    let longTapAction: (() -> Void)?

    init(id: AnyHashable, text: String, action: @escaping () -> Void, longTapAction: (() -> Void)?) {
        self.id = id
        self.text = text
        self.action = action
        self.longTapAction = longTapAction
    }

    func node() -> PeerInfoScreenItemNode {
        return PeerInfoScreenLuckgramVersionItemNode()
    }
}

private final class PeerInfoScreenLuckgramVersionItemNode: PeerInfoScreenItemNode {
    private let textNode: ImmediateTextNode
    private let activateArea: AccessibilityAreaNode

    private var item: PeerInfoScreenLuckgramVersionItem?

    override init() {
        self.textNode = ImmediateTextNode()
        self.textNode.displaysAsynchronously = false
        self.textNode.isUserInteractionEnabled = false
        self.textNode.textAlignment = .center
        self.textNode.maximumNumberOfLines = 2

        self.activateArea = AccessibilityAreaNode()
        self.activateArea.accessibilityTraits = [.staticText, .button]

        super.init()

        self.addSubnode(self.textNode)
        self.addSubnode(self.activateArea)
    }

    override func didLoad() {
        super.didLoad()

        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressGesture(_:)))
        longPress.minimumPressDuration = 0.5
        self.view.addGestureRecognizer(longPress)
    }

    override func update(context: AccountContext, width: CGFloat, safeInsets: UIEdgeInsets, presentationData: PresentationData, item: PeerInfoScreenItem, topItem: PeerInfoScreenItem?, bottomItem: PeerInfoScreenItem?, hasCorners: Bool, transition: ContainedViewLayoutTransition) -> CGFloat {
        guard let item = item as? PeerInfoScreenLuckgramVersionItem else {
            return 10.0
        }
        self.item = item

        let sideInset: CGFloat = 16.0 + safeInsets.left
        let sideInsetRight: CGFloat = 16.0 + safeInsets.right
        let verticalInset: CGFloat = 10.0

        self.textNode.attributedText = NSAttributedString(string: item.text, font: Font.regular(13.0), textColor: presentationData.theme.list.freeTextColor)
        self.activateArea.accessibilityLabel = item.text

        let textSize = self.textNode.updateLayout(CGSize(width: width - sideInset - sideInsetRight, height: .greatestFiniteMagnitude))
        let textFrame = CGRect(origin: CGPoint(x: floor((width - textSize.width) / 2.0), y: verticalInset), size: textSize)
        transition.updateFrame(node: self.textNode, frame: textFrame)

        let height = textSize.height + verticalInset * 2.0
        self.activateArea.frame = CGRect(origin: CGPoint(x: safeInsets.left, y: 0.0), size: CGSize(width: width - safeInsets.left - safeInsets.right, height: height))
        return height
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.item?.action()
        }
    }

    @objc private func longPressGesture(_ recognizer: UILongPressGestureRecognizer) {
        if case .began = recognizer.state {
            self.item?.longTapAction?()
        }
    }
}
