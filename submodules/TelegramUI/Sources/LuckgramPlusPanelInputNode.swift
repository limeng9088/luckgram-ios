import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramCore
import TelegramPresentationData
import ChatPresentationInterfaceState
import ChatInputNode
import GlassBackgroundComponent
import ChatTextInputPanelNode
import LuckgramUI

/// Luckgram specs#94: the WeChat-style 「+」 panel that takes the keyboard's place under the input bar.
/// 2 rows × 4 columns per page; more cells page sideways with page dots.
final class LuckgramPlusPanelInputNode: ChatInputNode, UIScrollViewDelegate {
    struct Item: Equatable {
        let action: LuckgramPlusAction
        /// No right to send this kind of message here: shown dimmed, the tap opens Telegram's own notice.
        let dimmed: Bool
    }

    var performAction: ((LuckgramPlusAction, Bool) -> Void)?

    private let backgroundView: BlurredBackgroundView
    private let backgroundTintView: UIImageView
    private let backgroundChromeView: UIImageView
    private let scrollView: UIScrollView
    private let pageControl: UIPageControl

    private var cells: [UIControl] = []
    private var items: [Item] = []
    private var theme: PresentationTheme?
    private var lastWidth: CGFloat = 0.0

    private static let columns = 4
    private static let rows = 2

    private let accountPeerId: EnginePeer.Id

    init(accountPeerId: EnginePeer.Id) {
        self.accountPeerId = accountPeerId

        self.backgroundView = BlurredBackgroundView(color: .black, enableBlur: true)
        self.backgroundTintView = UIImageView()
        self.backgroundChromeView = UIImageView()
        self.scrollView = UIScrollView()
        self.pageControl = UIPageControl()

        super.init()

        self.view.addSubview(self.backgroundView)
        self.view.addSubview(self.backgroundTintView)
        self.view.addSubview(self.backgroundChromeView)

        self.scrollView.isPagingEnabled = true
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.alwaysBounceVertical = false
        self.scrollView.scrollsToTop = false
        self.scrollView.delaysContentTouches = false
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.scrollView.delegate = self
        self.view.addSubview(self.scrollView)

        self.pageControl.isUserInteractionEnabled = false
        self.pageControl.hidesForSinglePage = true
        self.view.addSubview(self.pageControl)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        if width > 0.0 {
            self.pageControl.currentPage = Int((scrollView.contentOffset.x + width / 2.0) / width)
        }
    }

    static func items(for state: ChatPresentationInterfaceState, accountPeerId: EnginePeer.Id) -> [Item] {
        var mediaBanned = false
        var filesBanned = false
        var textBanned = false
        var canSendPolls = true

        if let peer = state.renderedPeer?.peer {
            if let user = peer as? TelegramUser {
                if user.botInfo == nil && user.id != accountPeerId {
                    canSendPolls = false
                }
            } else if peer is TelegramSecretChat {
                canSendPolls = false
            } else if let channel = peer as? TelegramChannel {
                mediaBanned = channel.hasBannedPermission(.banSendPhotos) != nil && channel.hasBannedPermission(.banSendVideos) != nil
                filesBanned = channel.hasBannedPermission(.banSendFiles) != nil
                textBanned = channel.hasBannedPermission(.banSendText) != nil
                if channel.hasBannedPermission(.banSendPolls) != nil || channel.isMonoForum {
                    canSendPolls = false
                }
            } else if let group = peer as? TelegramGroup {
                mediaBanned = group.hasBannedPermission(.banSendPhotos) && group.hasBannedPermission(.banSendVideos)
                filesBanned = group.hasBannedPermission(.banSendFiles)
                textBanned = group.hasBannedPermission(.banSendText)
                if group.hasBannedPermission(.banSendPolls) {
                    canSendPolls = false
                }
            }
        } else {
            canSendPolls = false
        }

        var isRegularChat = state.chatLocation.peerId != nil
        if case .scheduledMessages = state.subject {
            isRegularChat = false
        }
        let isSecret = state.renderedPeer?.peer is TelegramSecretChat

        var result: [Item] = [
            Item(action: .gallery, dimmed: mediaBanned),
            Item(action: .camera, dimmed: mediaBanned),
            Item(action: .file, dimmed: filesBanned),
            Item(action: .location, dimmed: textBanned),
            Item(action: .contact, dimmed: textBanned)
        ]
        if canSendPolls {
            result.append(Item(action: .poll, dimmed: false))
        }
        // Luckgram features: a switched-off feature has no cell (specs#94 需求 2)
        if !textBanned {
            if LuckgramQuickReplies.isEnabled && isRegularChat {
                result.append(Item(action: .quickReplies, dimmed: false))
            }
            if LuckgramSettings.shared.isEnabled(LuckgramFeatures.dictation) {
                result.append(Item(action: .dictation, dimmed: false))
            }
            if LuckgramAIWriting.isEnabled {
                result.append(Item(action: .aiWriting, dimmed: false))
            }
            if LuckgramTranslateOut.isEnabled && state.chatLocation.peerId != nil && !isSecret {
                result.append(Item(action: .translate, dimmed: false))
            }
        }
        return result
    }

    private func update(items: [Item]) {
        if self.items != items {
            self.items = items
            self.lastWidth = 0.0
        }
    }

    override func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, standardInputHeight: CGFloat, inputHeight: CGFloat, maximumHeight: CGFloat, inputPanelHeight: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState, layoutMetrics: LayoutMetrics, deviceMetrics: DeviceMetrics, isVisible: Bool, isExpanded: Bool) -> (CGFloat, CGFloat) {
        self.update(items: LuckgramPlusPanelInputNode.items(for: interfaceState, accountPeerId: self.accountPeerId))

        let theme = interfaceState.theme
        let updatedTheme = self.theme !== theme
        if updatedTheme {
            self.theme = theme
            self.lastWidth = 0.0
        }

        let panelHeight = standardInputHeight

        // background: same glass sheet as the bot keyboard
        var backgroundFrame = CGRect(origin: CGPoint(), size: CGSize(width: width, height: panelHeight))
        backgroundFrame.size.height += 32.0
        let cornerRadius: CGFloat = 30.0
        if self.backgroundChromeView.image == nil || updatedTheme {
            self.backgroundChromeView.image = GlassBackgroundView.generateForegroundImage(size: CGSize(width: cornerRadius * 2.0, height: cornerRadius * 2.0), isDark: theme.overallDarkAppearance, fillColor: .clear)
        }
        if self.backgroundTintView.image == nil {
            self.backgroundTintView.image = generateStretchableFilledCircleImage(diameter: cornerRadius * 2.0, color: .white)?.withRenderingMode(.alwaysTemplate)
        }
        self.backgroundTintView.tintColor = theme.chat.inputButtonPanel.panelBackgroundColor
        transition.updateFrame(view: self.backgroundView, frame: backgroundFrame)
        transition.updateFrame(view: self.backgroundTintView, frame: backgroundFrame)
        self.backgroundView.updateColor(color: .clear, forceKeepBlur: true, transition: .immediate)
        self.backgroundView.update(size: backgroundFrame.size, cornerRadius: cornerRadius, maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner], transition: transition)
        transition.updateFrame(view: self.backgroundChromeView, frame: backgroundFrame.insetBy(dx: -1.0, dy: 0.0))

        // grid
        let topInset: CGFloat = 20.0
        let cellHeight: CGFloat = 58.0 + 6.0 + 16.0
        let rowSpacing: CGFloat = 14.0
        let gridHeight = topInset + CGFloat(LuckgramPlusPanelInputNode.rows) * cellHeight + CGFloat(LuckgramPlusPanelInputNode.rows - 1) * rowSpacing
        let pageWidth = width
        let perPage = LuckgramPlusPanelInputNode.columns * LuckgramPlusPanelInputNode.rows
        let pageCount = max(1, (self.items.count + perPage - 1) / perPage)

        self.scrollView.frame = CGRect(x: 0.0, y: 0.0, width: pageWidth, height: gridHeight)
        self.scrollView.contentSize = CGSize(width: pageWidth * CGFloat(pageCount), height: gridHeight)

        self.pageControl.numberOfPages = pageCount
        self.pageControl.pageIndicatorTintColor = theme.chat.inputPanel.panelControlColor.withAlphaComponent(0.25)
        self.pageControl.currentPageIndicatorTintColor = theme.chat.inputPanel.panelControlColor
        self.pageControl.frame = CGRect(x: 0.0, y: gridHeight + 4.0, width: width, height: 20.0)

        if self.lastWidth != width {
            self.lastWidth = width
            for cell in self.cells {
                cell.removeFromSuperview()
            }
            self.cells.removeAll()

            let sideInset: CGFloat = 12.0 + max(leftInset, rightInset)
            let columnWidth = floor((pageWidth - sideInset * 2.0) / CGFloat(LuckgramPlusPanelInputNode.columns))
            for (index, item) in self.items.enumerated() {
                let page = index / perPage
                let indexInPage = index % perPage
                let row = indexInPage / LuckgramPlusPanelInputNode.columns
                let column = indexInPage % LuckgramPlusPanelInputNode.columns
                let frame = CGRect(
                    x: CGFloat(page) * pageWidth + sideInset + CGFloat(column) * columnWidth,
                    y: topInset + CGFloat(row) * (cellHeight + rowSpacing),
                    width: columnWidth,
                    height: cellHeight
                )
                let cell = self.makeCell(item: item, theme: theme, frame: frame)
                cell.tag = index
                self.scrollView.addSubview(cell)
                self.cells.append(cell)
            }
            if self.scrollView.contentOffset.x > self.scrollView.contentSize.width - pageWidth {
                self.scrollView.contentOffset = CGPoint()
            }
            self.scrollViewDidScroll(self.scrollView)
        }

        return (panelHeight, 0.0)
    }

    private func makeCell(item: Item, theme: PresentationTheme, frame: CGRect) -> UIControl {
        let cell = UIControl(frame: frame)
        cell.accessibilityLabel = item.action.title
        cell.accessibilityTraits = [.button]
        cell.isAccessibilityElement = true

        let squareSize: CGFloat = 58.0
        let square = UIView(frame: CGRect(x: floor((frame.width - squareSize) / 2.0), y: 0.0, width: squareSize, height: squareSize))
        square.isUserInteractionEnabled = false
        square.layer.cornerRadius = 14.0
        square.layer.cornerCurve = .continuous
        square.backgroundColor = theme.chat.inputPanel.panelControlColor.withAlphaComponent(theme.overallDarkAppearance ? 0.16 : 0.08)
        cell.addSubview(square)

        let icon = UIImageView(image: UIImage(systemName: item.action.systemImageName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24.0, weight: .regular)))
        icon.tintColor = theme.chat.inputPanel.panelControlColor
        icon.contentMode = .center
        icon.frame = square.bounds
        square.addSubview(icon)

        let label = UILabel(frame: CGRect(x: 2.0, y: squareSize + 6.0, width: frame.width - 4.0, height: 16.0))
        label.isUserInteractionEnabled = false
        label.text = item.action.title
        label.font = UIFont.systemFont(ofSize: 12.0)
        label.textColor = theme.chat.inputPanel.inputPlaceholderColor
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label)

        cell.alpha = item.dimmed ? 0.4 : 1.0
        cell.addTarget(self, action: #selector(self.cellPressed(_:)), for: .touchUpInside)
        cell.addTarget(self, action: #selector(self.cellHighlight(_:)), for: [.touchDown, .touchDragEnter])
        cell.addTarget(self, action: #selector(self.cellUnhighlight(_:)), for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        return cell
    }

    @objc private func cellHighlight(_ sender: UIControl) {
        sender.subviews.first?.alpha = 0.6
    }

    @objc private func cellUnhighlight(_ sender: UIControl) {
        UIView.animate(withDuration: 0.2) {
            sender.subviews.first?.alpha = 1.0
        }
    }

    @objc private func cellPressed(_ sender: UIControl) {
        guard sender.tag >= 0 && sender.tag < self.items.count else {
            return
        }
        let item = self.items[sender.tag]
        self.performAction?(item.action, item.dimmed)
    }
}
