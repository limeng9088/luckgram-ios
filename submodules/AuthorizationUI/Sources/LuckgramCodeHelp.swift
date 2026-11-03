import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import LuckgramUI

/// Luckgram 97 strings; same texts as Android `CodeHelpCard`.
enum LuckgramCodeHelpStrings {
    static var title: String { LuckgramStrings.pick("验证码已发到你的 Telegram", "Your code was sent to Telegram") }
    static var steps: [String] {
        return [
            LuckgramStrings.pick("在另一台已登录的设备上打开 Telegram（或 Luckgram）。", "Open Telegram (or Luckgram) on another device where you're logged in."),
            LuckgramStrings.pick("在聊天列表里找到官方账号「Telegram」发来的消息（带蓝色认证标）。", "In the chat list, find the message from the official \"Telegram\" account (with the blue check)."),
            LuckgramStrings.pick("把消息里的 5–6 位验证码填到上面。", "Enter the 5–6 digit code from that message above.")
        ]
    }
    static var ok: String { LuckgramStrings.pick("知道了", "OK") }
    static var helpButton: String { LuckgramStrings.pick("收不到验证码？", "How can I receive the code?") }
    static var helpTitle: String { LuckgramStrings.pick("怎样收到验证码", "How to receive the code") }
    static var helpTexts: [String] {
        return [
            LuckgramStrings.pick("验证码会优先发到你已登录的 Telegram App 里，而不是短信。请在手机、电脑或平板上已登录的 Telegram（或 Luckgram）中查看官方「Telegram」账号的消息。", "The code goes to the Telegram app where you're already logged in, not by SMS. Check the message from the official \"Telegram\" account in Telegram (or Luckgram) on your phone, computer or tablet."),
            LuckgramStrings.pick("如果所有设备都已退出登录，点验证码页下方的「没有收到验证码？」，可以改为通过短信接收（是否可用由 Telegram 决定）。", "If you're logged out everywhere, tap \"Didn't get the code?\" below the code field to get it by SMS instead (if Telegram allows it)."),
            LuckgramStrings.pick("如果一直连不上网络，先点右上角的代理图标配置代理，再重新获取验证码。", "If you can't connect, tap the proxy icon at the top right to set up a proxy first, then request the code again.")
        ]
    }

    /// "Telegram" / "Luckgram" in the accent colour and bold.
    static func highlighted(_ text: String, font: UIFont, boldFont: UIFont, color: UIColor, accent: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let nsText = text as NSString
        for word in ["Telegram", "Luckgram"] {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while true {
                let range = nsText.range(of: word, options: [], range: searchRange)
                if range.location == NSNotFound {
                    break
                }
                result.addAttributes([.font: boldFont, .foregroundColor: accent], range: range)
                let next = range.location + range.length
                searchRange = NSRange(location: next, length: nsText.length - next)
            }
        }
        return result
    }
}

/// The card under the code field when the code was sent to the Telegram app (`.otherSession`).
final class LuckgramCodeHelpCardNode: ASDisplayNode {
    /// "OK" hides the card for the rest of this app session (this login).
    static var dismissed = false

    private let backgroundNode = ASDisplayNode()
    private let iconNode = ASImageNode()
    private let titleNode = ImmediateTextNode()
    private let stepNodes: [ImmediateTextNode]
    private let numberNodes: [ImmediateTextNode]
    private let buttonNode = HighlightableButtonNode()
    private let buttonBackgroundNode = ASImageNode()
    private let buttonTitleNode = ImmediateTextNode()

    var dismiss: (() -> Void)?

    init(theme: PresentationTheme) {
        let steps = LuckgramCodeHelpStrings.steps
        self.stepNodes = steps.map { _ in ImmediateTextNode() }
        self.numberNodes = steps.map { _ in ImmediateTextNode() }
        super.init()

        let primary = theme.list.itemPrimaryTextColor
        let secondary = theme.list.itemSecondaryTextColor
        let accent = theme.list.itemAccentColor

        self.backgroundNode.backgroundColor = primary.withAlphaComponent(0.06)
        self.backgroundNode.cornerRadius = 16.0
        self.addSubnode(self.backgroundNode)

        self.iconNode.displaysAsynchronously = false
        self.iconNode.image = UIImage(systemName: "bubble.left.and.bubble.right.fill")?.withTintColor(accent, renderingMode: .alwaysOriginal)
        self.addSubnode(self.iconNode)

        self.titleNode.maximumNumberOfLines = 0
        self.titleNode.attributedText = LuckgramCodeHelpStrings.highlighted(LuckgramCodeHelpStrings.title, font: Font.semibold(15.0), boldFont: Font.semibold(15.0), color: primary, accent: accent)
        self.addSubnode(self.titleNode)

        for (index, text) in steps.enumerated() {
            let number = self.numberNodes[index]
            number.attributedText = NSAttributedString(string: "\(index + 1).", font: Font.regular(14.0), textColor: secondary)
            self.addSubnode(number)
            let step = self.stepNodes[index]
            step.maximumNumberOfLines = 0
            step.lineSpacing = 0.1
            step.attributedText = LuckgramCodeHelpStrings.highlighted(text, font: Font.regular(14.0), boldFont: Font.semibold(14.0), color: secondary, accent: accent)
            self.addSubnode(step)
        }

        self.buttonBackgroundNode.displaysAsynchronously = false
        self.buttonBackgroundNode.cornerRadius = 10.0
        self.buttonBackgroundNode.clipsToBounds = true
        self.buttonBackgroundNode.image = generateGradientImage(size: CGSize(width: 200.0, height: 40.0), colors: [UIColor(rgb: 0x3c8cff), UIColor(rgb: 0x7a5cff)], locations: [0.0, 1.0], direction: .horizontal)
        self.buttonNode.addSubnode(self.buttonBackgroundNode)
        self.buttonTitleNode.attributedText = NSAttributedString(string: LuckgramCodeHelpStrings.ok, font: Font.semibold(15.0), textColor: .white)
        self.buttonNode.addSubnode(self.buttonTitleNode)
        self.buttonNode.accessibilityLabel = LuckgramCodeHelpStrings.ok
        self.buttonNode.accessibilityTraits = [.button]
        self.addSubnode(self.buttonNode)
        self.buttonNode.addTarget(self, action: #selector(self.okPressed), forControlEvents: .touchUpInside)
    }

    @objc private func okPressed() {
        LuckgramCodeHelpCardNode.dismissed = true
        self.dismiss?()
    }

    /// Lays out for `width` and returns the card size.
    func updateLayout(width: CGFloat) -> CGSize {
        let inset: CGFloat = 16.0
        let contentWidth = width - inset * 2.0
        var y: CGFloat = 14.0

        let iconSize = CGSize(width: 24.0, height: 20.0)
        let titleSize = self.titleNode.updateLayout(CGSize(width: contentWidth - iconSize.width - 10.0, height: .greatestFiniteMagnitude))
        let headerHeight = max(iconSize.height, titleSize.height)
        self.iconNode.frame = CGRect(origin: CGPoint(x: inset, y: y + floor((headerHeight - iconSize.height) / 2.0)), size: iconSize)
        self.titleNode.frame = CGRect(origin: CGPoint(x: inset + iconSize.width + 10.0, y: y + floor((headerHeight - titleSize.height) / 2.0)), size: titleSize)
        y += headerHeight + 10.0

        for index in 0 ..< self.stepNodes.count {
            let numberSize = self.numberNodes[index].updateLayout(CGSize(width: 20.0, height: .greatestFiniteMagnitude))
            let stepSize = self.stepNodes[index].updateLayout(CGSize(width: contentWidth - 20.0, height: .greatestFiniteMagnitude))
            self.numberNodes[index].frame = CGRect(origin: CGPoint(x: inset, y: y), size: numberSize)
            self.stepNodes[index].frame = CGRect(origin: CGPoint(x: inset + 20.0, y: y), size: stepSize)
            y += stepSize.height + 6.0
        }
        y += 6.0

        let buttonFrame = CGRect(origin: CGPoint(x: inset, y: y), size: CGSize(width: contentWidth, height: 40.0))
        self.buttonNode.frame = buttonFrame
        self.buttonBackgroundNode.frame = CGRect(origin: CGPoint(), size: buttonFrame.size)
        let buttonTitleSize = self.buttonTitleNode.updateLayout(buttonFrame.size)
        self.buttonTitleNode.frame = CGRect(origin: CGPoint(x: floor((buttonFrame.width - buttonTitleSize.width) / 2.0), y: floor((buttonFrame.height - buttonTitleSize.height) / 2.0)), size: buttonTitleSize)
        y += 40.0 + 14.0

        let size = CGSize(width: width, height: y)
        self.backgroundNode.frame = CGRect(origin: CGPoint(), size: size)
        return size
    }
}

/// Bottom sheet for "How can I receive the code?".
func luckgramPresentCodeHelp(present: (UIViewController) -> Void, sourceView: UIView?) {
    let message = LuckgramCodeHelpStrings.helpTexts.map { "• " + $0 }.joined(separator: "\n\n")
    let sheet = UIAlertController(title: LuckgramCodeHelpStrings.helpTitle, message: message, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: LuckgramCodeHelpStrings.ok, style: .cancel))
    if let sourceView {
        sheet.popoverPresentationController?.sourceView = sourceView
        sheet.popoverPresentationController?.sourceRect = CGRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1.0, height: 1.0)
    }
    present(sheet)
}
