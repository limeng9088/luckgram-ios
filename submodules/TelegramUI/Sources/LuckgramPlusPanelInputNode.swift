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
    private var lastTopInset: CGFloat = 0.0
    private var wasVisible = false

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
        // specs#147: the two rows sit in the middle of the panel instead of hugging its top
        let cellHeight: CGFloat = 60.0 + 7.0 + 16.0
        let rowSpacing: CGFloat = 20.0
        let rowsHeight = CGFloat(LuckgramPlusPanelInputNode.rows) * cellHeight + CGFloat(LuckgramPlusPanelInputNode.rows - 1) * rowSpacing
        let topInset = max(18.0, min(48.0, floor((panelHeight - bottomInset - 24.0 - rowsHeight) / 2.0)))
        let gridHeight = topInset + CGFloat(LuckgramPlusPanelInputNode.rows) * cellHeight + CGFloat(LuckgramPlusPanelInputNode.rows - 1) * rowSpacing
        let pageWidth = width
        let perPage = LuckgramPlusPanelInputNode.columns * LuckgramPlusPanelInputNode.rows
        let pageCount = max(1, (self.items.count + perPage - 1) / perPage)

        self.scrollView.frame = CGRect(x: 0.0, y: 0.0, width: pageWidth, height: gridHeight)
        self.scrollView.contentSize = CGSize(width: pageWidth * CGFloat(pageCount), height: gridHeight)

        self.pageControl.numberOfPages = pageCount
        self.pageControl.pageIndicatorTintColor = LuckgramPlusPanelColors.dotOther(dark: theme.overallDarkAppearance)
        self.pageControl.currentPageIndicatorTintColor = LuckgramPlusPanelColors.dotCurrent(dark: theme.overallDarkAppearance)
        self.pageControl.frame = CGRect(x: 0.0, y: gridHeight + 4.0, width: width, height: 20.0)

        if self.lastWidth != width || self.lastTopInset != topInset {
            self.lastWidth = width
            self.lastTopInset = topInset
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

        if isVisible && !self.wasVisible {
            self.animateCellsIn()
        }
        self.wasVisible = isVisible

        return (panelHeight, 0.0)
    }

    /// The panel just came up: the cells of the page in view appear one after another.
    private func animateCellsIn() {
        let perPage = LuckgramPlusPanelInputNode.columns * LuckgramPlusPanelInputNode.rows
        let page = self.pageControl.currentPage
        for (index, cell) in self.cells.enumerated() {
            if index / perPage != page {
                continue
            }
            let indexInPage = index % perPage
            let step = indexInPage / LuckgramPlusPanelInputNode.columns + indexInPage % LuckgramPlusPanelInputNode.columns
            let alpha = cell.alpha
            cell.alpha = 0.0
            cell.transform = CGAffineTransform(translationX: 0.0, y: 10.0).scaledBy(x: 0.82, y: 0.82)
            UIView.animate(withDuration: 0.42, delay: 0.04 + Double(step) * 0.028, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
                cell.alpha = alpha
                cell.transform = .identity
            }, completion: nil)
        }
    }

    private func makeCell(item: Item, theme: PresentationTheme, frame: CGRect) -> UIControl {
        let cell = UIControl(frame: frame)
        cell.accessibilityLabel = item.action.title
        cell.accessibilityTraits = [.button]
        cell.isAccessibilityElement = true

        let squareSize: CGFloat = 60.0
        let square = UIView(frame: CGRect(x: floor((frame.width - squareSize) / 2.0), y: 0.0, width: squareSize, height: squareSize))
        square.isUserInteractionEnabled = false
        square.layer.cornerRadius = 18.0
        square.layer.cornerCurve = .continuous
        square.clipsToBounds = true
        let colors = LuckgramPlusPanelColors.square(item.action)
        let gradient = CAGradientLayer()
        gradient.frame = square.bounds
        gradient.colors = [colors.top.cgColor, colors.bottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1.0)
        square.layer.addSublayer(gradient)
        cell.addSubview(square)

        // white on color reads better filled; not every symbol has a filled form
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 25.0, weight: .medium)
        let symbolName = item.action.systemImageName
        let icon = UIImageView(image: UIImage(systemName: symbolName + ".fill", withConfiguration: symbolConfiguration) ?? UIImage(systemName: symbolName, withConfiguration: symbolConfiguration))
        icon.tintColor = LuckgramPlusPanelColors.icon(dark: theme.overallDarkAppearance)
        icon.contentMode = .center
        icon.frame = square.bounds
        square.addSubview(icon)

        let label = UILabel(frame: CGRect(x: 2.0, y: squareSize + 7.0, width: frame.width - 4.0, height: 16.0))
        label.isUserInteractionEnabled = false
        label.text = item.action.title
        label.font = UIFont.systemFont(ofSize: 12.0)
        label.textColor = LuckgramPlusPanelColors.title(dark: theme.overallDarkAppearance)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label)

        cell.alpha = item.dimmed ? LuckgramPlusPanelColors.dimmedAlpha : 1.0
        cell.addTarget(self, action: #selector(self.cellPressed(_:)), for: .touchUpInside)
        cell.addTarget(self, action: #selector(self.cellHighlight(_:)), for: [.touchDown, .touchDragEnter])
        cell.addTarget(self, action: #selector(self.cellUnhighlight(_:)), for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        return cell
    }

    @objc private func cellHighlight(_ sender: UIControl) {
        UIView.animate(withDuration: 0.09, delay: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            sender.subviews.first?.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }, completion: nil)
    }

    @objc private func cellUnhighlight(_ sender: UIControl) {
        UIView.animate(withDuration: 0.35, delay: 0.0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            sender.subviews.first?.transform = .identity
        }, completion: nil)
    }

    @objc private func cellPressed(_ sender: UIControl) {
        guard sender.tag >= 0 && sender.tag < self.items.count else {
            return
        }
        let item = self.items[sender.tag]
        self.performAction?(item.action, item.dimmed)
    }
}
