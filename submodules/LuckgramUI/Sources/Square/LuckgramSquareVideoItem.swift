import Foundation
import UIKit
import AVFoundation
import AVKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import LuckgramDiscover

/// Inline video of a Square post (spec 26 item 3): cover with the duration badge, muted autoplay
/// (looping) while the row is on screen, tap for the full-screen player with sound. The player is
/// released when the row leaves the list, so a feed never holds more than the visible players.
final class LuckgramSquareVideoItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let video: SquareLogic.Video
    let sectionId: ItemListSectionId
    let style: ItemListStyle
    let action: (() -> Void)?

    let selectable: Bool

    init(presentationData: ItemListPresentationData, video: SquareLogic.Video, sectionId: ItemListSectionId, style: ItemListStyle, action: (() -> Void)?) {
        self.presentationData = presentationData
        self.video = video
        self.sectionId = sectionId
        self.style = style
        self.action = action
        self.selectable = action != nil
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = LuckgramSquareVideoItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? LuckgramSquareVideoItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply()
                        })
                    }
                }
            }
        }
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action?()
    }

    /// Height for the given width: the video's aspect ratio, capped so a portrait clip doesn't fill the screen.
    static func height(width: CGFloat, video: SquareLogic.Video) -> CGFloat {
        guard video.width > 0, video.height > 0 else {
            return floor(width * 9.0 / 16.0)
        }
        var ratio = CGFloat(video.height) / CGFloat(video.width)
        ratio = max(9.0 / 16.0, min(ratio, 5.0 / 4.0))
        return floor(width * ratio)
    }
}

final class LuckgramSquareVideoItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode
    private let coverNode: ASImageNode
    private let playerNode: ASDisplayNode
    private let badgeNode: ImmediateTextNode
    private let badgeBackground: ASDisplayNode
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: Any?
    private var coverDisposable: Disposable?
    private var currentUrl: String?

    private var item: LuckgramSquareVideoItem?

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true
        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true
        self.maskNode = ASImageNode()
        self.coverNode = ASImageNode()
        self.coverNode.contentMode = .scaleAspectFill
        self.coverNode.clipsToBounds = true
        self.coverNode.cornerRadius = 6.0
        self.coverNode.displaysAsynchronously = false
        self.playerNode = ASDisplayNode()
        self.playerNode.clipsToBounds = true
        self.playerNode.cornerRadius = 6.0
        self.playerNode.alpha = 0.0
        self.badgeBackground = ASDisplayNode()
        self.badgeBackground.backgroundColor = UIColor(white: 0.0, alpha: 0.6)
        self.badgeBackground.cornerRadius = 10.0
        self.badgeNode = ImmediateTextNode()
        super.init(layerBacked: false)
        self.addSubnode(self.coverNode)
        self.addSubnode(self.playerNode)
        self.addSubnode(self.badgeBackground)
        self.addSubnode(self.badgeNode)
    }

    deinit {
        self.coverDisposable?.dispose()
        self.stopPlayback()
    }

    override func didLoad() {
        super.didLoad()
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        self.playerNode.layer.addSublayer(layer)
        self.playerLayer = layer
    }

    private func startPlayback(url: String) {
        guard self.player == nil, let target = URL(string: url) else {
            return
        }
        let item = AVPlayerItem(url: target)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player
        self.playerLayer?.player = player
        self.loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        player.play()
        self.playerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
        self.playerNode.alpha = 1.0
    }

    private func stopPlayback() {
        if let observer = self.loopObserver {
            NotificationCenter.default.removeObserver(observer)
            self.loopObserver = nil
        }
        self.player?.pause()
        self.playerLayer?.player = nil
        self.player = nil
        self.playerNode.alpha = 0.0
    }

    override var visibility: ListViewItemNodeVisibility {
        didSet {
            switch self.visibility {
            case .visible:
                if let url = self.item?.video.url {
                    self.startPlayback(url: url)
                }
            default:
                self.stopPlayback()
            }
        }
    }

    func asyncLayout() -> (_ item: LuckgramSquareVideoItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params, neighbors in
            let leftInset: CGFloat = 16.0 + params.leftInset
            let rightInset: CGFloat = 16.0 + params.rightInset
            let itemBackgroundColor: UIColor
            let itemSeparatorColor: UIColor
            switch item.style {
            case .plain:
                itemBackgroundColor = item.presentationData.theme.list.plainBackgroundColor
                itemSeparatorColor = item.presentationData.theme.list.itemPlainSeparatorColor
            case .blocks:
                itemBackgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor
                itemSeparatorColor = item.presentationData.theme.list.itemBlocksSeparatorColor
            }
            let placeholderColor = item.presentationData.theme.list.mediaPlaceholderColor
            let width = params.width - leftInset - rightInset
            let height = LuckgramSquareVideoItem.height(width: width, video: item.video)
            let contentSize = CGSize(width: params.width, height: height + 16.0)
            let insets: UIEdgeInsets
            switch item.style {
            case .plain:
                insets = itemListNeighborsPlainInsets(neighbors)
            case .blocks:
                insets = itemListNeighborsGroupedInsets(neighbors, params)
            }
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let separatorHeight = UIScreenPixel

            return (layout, { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                strongSelf.topStripeNode.backgroundColor = itemSeparatorColor
                strongSelf.bottomStripeNode.backgroundColor = itemSeparatorColor
                strongSelf.backgroundNode.backgroundColor = itemBackgroundColor

                switch item.style {
                case .plain:
                    if strongSelf.backgroundNode.supernode != nil {
                        strongSelf.backgroundNode.removeFromSupernode()
                    }
                    if strongSelf.topStripeNode.supernode != nil {
                        strongSelf.topStripeNode.removeFromSupernode()
                    }
                    if strongSelf.bottomStripeNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 0)
                    }
                    if strongSelf.maskNode.supernode != nil {
                        strongSelf.maskNode.removeFromSupernode()
                    }
                    strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: leftInset, y: contentSize.height - separatorHeight), size: CGSize(width: params.width - leftInset, height: separatorHeight))
                case .blocks:
                    if strongSelf.backgroundNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                    }
                    if strongSelf.topStripeNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                    }
                    if strongSelf.bottomStripeNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                    }
                    if strongSelf.maskNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                    }
                    let hasCorners = itemListHasRoundedBlockLayout(params)
                    var hasTopCorners = false
                    var hasBottomCorners = false
                    switch neighbors.top {
                    case .sameSection(false):
                        strongSelf.topStripeNode.isHidden = true
                    default:
                        hasTopCorners = true
                        strongSelf.topStripeNode.isHidden = hasCorners
                    }
                    let bottomStripeInset: CGFloat
                    let bottomStripeOffset: CGFloat
                    switch neighbors.bottom {
                    case .sameSection(false):
                        bottomStripeInset = 16.0
                        bottomStripeOffset = -separatorHeight
                        strongSelf.bottomStripeNode.isHidden = false
                    default:
                        bottomStripeInset = 0.0
                        bottomStripeOffset = 0.0
                        hasBottomCorners = true
                        strongSelf.bottomStripeNode.isHidden = hasCorners
                    }
                    strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.presentationData.theme, top: hasTopCorners, bottom: hasBottomCorners) : nil
                    strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                    strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.inset(by: UIEdgeInsets(top: 0.0, left: params.leftInset, bottom: 0.0, right: params.rightInset))
                    strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: separatorHeight))
                    strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height + bottomStripeOffset), size: CGSize(width: params.width - bottomStripeInset, height: separatorHeight))
                }

                let frame = CGRect(x: leftInset, y: 8.0, width: width, height: height)
                strongSelf.coverNode.frame = frame
                strongSelf.coverNode.backgroundColor = placeholderColor
                strongSelf.playerNode.frame = frame
                strongSelf.playerLayer?.frame = CGRect(origin: .zero, size: frame.size)

                if strongSelf.currentUrl != item.video.url {
                    strongSelf.currentUrl = item.video.url
                    strongSelf.stopPlayback()
                    strongSelf.coverNode.image = nil
                    strongSelf.coverDisposable?.dispose()
                    if let cover = item.video.coverUrl {
                        strongSelf.coverDisposable = LuckgramSquare.image(url: cover).start(next: { [weak strongSelf] image in
                            strongSelf?.coverNode.image = image
                        })
                    }
                }

                strongSelf.badgeNode.attributedText = NSAttributedString(string: "▶ " + SquareLogic.formatDuration(item.video.durationSeconds), font: Font.semibold(12.0), textColor: .white)
                let badgeSize = strongSelf.badgeNode.updateLayout(CGSize(width: 200.0, height: 20.0))
                let badgeFrame = CGRect(x: frame.minX + 8.0, y: frame.maxY - 8.0 - badgeSize.height - 6.0, width: badgeSize.width + 16.0, height: badgeSize.height + 6.0)
                strongSelf.badgeBackground.frame = badgeFrame
                strongSelf.badgeNode.frame = CGRect(x: badgeFrame.minX + 8.0, y: badgeFrame.minY + 3.0, width: badgeSize.width, height: badgeSize.height)
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}

/// Full-screen playback with sound (spec 26 item 3), through the system player.
enum LuckgramSquareVideoPlayer {
    static func present(_ video: SquareLogic.Video, context: AccountContext, fallback: ((UIViewController) -> Void)?) {
        guard let url = URL(string: video.url) else {
            return
        }
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        player.isMuted = false
        controller.player = player
        controller.modalPresentationStyle = .fullScreen
        if let window = context.sharedContext.mainWindow {
            window.presentNative(controller)
        } else {
            fallback?(controller)
        }
        player.play()
    }
}
