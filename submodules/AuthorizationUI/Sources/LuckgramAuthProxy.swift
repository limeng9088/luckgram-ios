import Foundation
import UIKit
import ObjectiveC
import AsyncDisplayKit
import Display
import TelegramPresentationData

/// Luckgram 91: state of the proxy icon shown at the top right of every login page.
enum LuckgramAuthProxyStatus: Equatable {
    /// No proxy turned on: grey outline.
    case off
    /// Proxy on, still connecting: accent icon, pulsing.
    case connecting
    /// Proxy on and connected: accent icon with the check mark.
    case connected
}

private func luckgramProxyIcon(color: UIColor, status: LuckgramAuthProxyStatus) -> UIImage? {
    return generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
        if let image = generateTintedImage(image: UIImage(bundleImageName: "Chat List/ProxyShieldIcon"), color: color), let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(origin: CGPoint(), size: image.size))
        }
        let overlayName: String
        switch status {
        case .connected:
            overlayName = "Chat List/ProxyCheckIcon"
        case .off, .connecting:
            overlayName = "Chat List/ProxyOnIcon"
        }
        if let image = generateTintedImage(image: UIImage(bundleImageName: overlayName), color: color), let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(origin: CGPoint(), size: image.size))
        }
    })
}

/// The icon in the navigation bar (same shield as the chat list title's proxy icon).
final class LuckgramAuthProxyNode: ASDisplayNode {
    private let iconNode: ASImageNode
    private(set) var status: LuckgramAuthProxyStatus = .off
    private var theme: PresentationTheme

    init(theme: PresentationTheme, status: LuckgramAuthProxyStatus) {
        self.theme = theme
        self.iconNode = ASImageNode()
        self.iconNode.isLayerBacked = true
        self.iconNode.displayWithoutProcessing = true
        self.iconNode.displaysAsynchronously = false
        super.init()
        self.addSubnode(self.iconNode)
        self.iconNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: 30.0, height: 30.0))
        self.frame = CGRect(origin: CGPoint(), size: CGSize(width: 30.0, height: 30.0))
        self.update(theme: theme, status: status, force: true)
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 30.0, height: 30.0)
    }

    func update(theme: PresentationTheme, status: LuckgramAuthProxyStatus, force: Bool = false) {
        if !force && self.theme === theme && self.status == status {
            return
        }
        self.theme = theme
        self.status = status
        let color: UIColor
        switch status {
        case .off:
            color = theme.list.itemSecondaryTextColor
        case .connecting, .connected:
            color = theme.list.itemAccentColor
        }
        self.iconNode.image = luckgramProxyIcon(color: color, status: status)
        self.iconNode.layer.removeAnimation(forKey: "luckgramPulse")
        if status == .connecting {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1.0
            animation.toValue = 0.3
            animation.duration = 0.7
            animation.autoreverses = true
            animation.repeatCount = .infinity
            self.iconNode.layer.add(animation, forKey: "luckgramPulse")
        }
    }
}

private var luckgramProxyBarItemKey: UInt8 = 0

extension ViewController {
    /// The proxy item installed by `AuthorizationSequenceController` (Luckgram 91); nil elsewhere.
    var luckgramProxyBarItem: UIBarButtonItem? {
        get {
            return objc_getAssociatedObject(self, &luckgramProxyBarItemKey) as? UIBarButtonItem
        }
        set {
            objc_setAssociatedObject(self, &luckgramProxyBarItemKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Sets the page's own right item and keeps the proxy icon to its right (rightmost).
    func luckgramSetRightItem(_ item: UIBarButtonItem?) {
        var items: [UIBarButtonItem] = []
        if let item {
            items.append(item)
        }
        if let proxy = self.luckgramProxyBarItem, item !== proxy {
            items.append(proxy)
        }
        if items.count <= 1 {
            self.navigationItem.rightBarButtonItems = nil
            self.navigationItem.rightBarButtonItem = items.first
        } else {
            self.navigationItem.rightBarButtonItems = items
        }
    }

    /// The page's own right item (everything but the proxy icon).
    var luckgramOwnRightItem: UIBarButtonItem? {
        let proxy = self.luckgramProxyBarItem
        if let items = self.navigationItem.rightBarButtonItems, !items.isEmpty {
            return items.first(where: { $0 !== proxy })
        }
        let item = self.navigationItem.rightBarButtonItem
        return item === proxy ? nil : item
    }
}
