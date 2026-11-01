import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import LuckgramDiscover

/// Image grid of a Square post (spec 26 item 3): one image wide, otherwise up to three per row.
/// Images are loaded through `LuckgramSquare.image(url:)` and shown with a placeholder until
/// they arrive. Tap opens the post.
final class LuckgramSquareImagesItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let images: [SquareLogic.Image]
    let sectionId: ItemListSectionId
    let style: ItemListStyle
    let action: (() -> Void)?

    let selectable: Bool

    init(presentationData: ItemListPresentationData, images: [SquareLogic.Image], sectionId: ItemListSectionId, style: ItemListStyle, action: (() -> Void)?) {
        self.presentationData = presentationData
        self.images = Array(images.prefix(SquareLogic.imagesMax))
        self.sectionId = sectionId
        self.style = style
        self.action = action
        self.selectable = action != nil
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = LuckgramSquareImagesItemNode()
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
            if let nodeValue = node() as? LuckgramSquareImagesItemNode {
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

    /// Grid geometry shared with the layout: columns, rows and cell size for `count` images.
    static func grid(count: Int, width: CGFloat) -> (columns: Int, rows: Int, cell: CGSize) {
        let n = max(0, min(count, SquareLogic.imagesMax))
        if n == 0 {
            return (0, 0, .zero)
        }
        let columns = n == 1 ? 1 : (n == 4 ? 2 : 3)
        let rows = (n + columns - 1) / columns
        let spacing: CGFloat = 4.0
        let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight: CGFloat = n == 1 ? min(cellWidth * 0.66, 240.0) : cellWidth
        return (columns, rows, CGSize(width: cellWidth, height: cellHeight))
    }
}

final class LuckgramSquareImagesItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode
    private var imageNodes: [ASImageNode] = []
    private var loadDisposables: [Disposable] = []
    private var loadedUrls: [String] = []

    private var item: LuckgramSquareImagesItem?

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true
        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true
        self.maskNode = ASImageNode()
        super.init(layerBacked: false)
    }

    deinit {
        for d in self.loadDisposables {
            d.dispose()
        }
    }

    func asyncLayout() -> (_ item: LuckgramSquareImagesItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
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

            let gridWidth = params.width - leftInset - rightInset
            let grid = LuckgramSquareImagesItem.grid(count: item.images.count, width: gridWidth)
            let spacing: CGFloat = 4.0
            let gridHeight = grid.rows > 0 ? grid.cell.height * CGFloat(grid.rows) + spacing * CGFloat(grid.rows - 1) : 0.0
            let contentSize = CGSize(width: params.width, height: gridHeight + 16.0)
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

                // image nodes: reuse, add or remove to match the count
                while strongSelf.imageNodes.count > item.images.count {
                    strongSelf.imageNodes.removeLast().removeFromSupernode()
                }
                while strongSelf.imageNodes.count < item.images.count {
                    let node = ASImageNode()
                    node.contentMode = .scaleAspectFill
                    node.clipsToBounds = true
                    node.cornerRadius = 6.0
                    node.displaysAsynchronously = false
                    strongSelf.addSubnode(node)
                    strongSelf.imageNodes.append(node)
                }
                let urls = item.images.map { $0.url }
                if urls != strongSelf.loadedUrls {
                    for d in strongSelf.loadDisposables {
                        d.dispose()
                    }
                    strongSelf.loadDisposables.removeAll()
                    strongSelf.loadedUrls = urls
                    for (i, url) in urls.enumerated() {
                        let node = strongSelf.imageNodes[i]
                        node.image = nil
                        node.backgroundColor = placeholderColor
                        strongSelf.loadDisposables.append(LuckgramSquare.image(url: url).start(next: { [weak node] image in
                            node?.image = image
                        }))
                    }
                }
                for (i, node) in strongSelf.imageNodes.enumerated() {
                    let row = i / max(1, grid.columns)
                    let col = i % max(1, grid.columns)
                    node.frame = CGRect(x: leftInset + (grid.cell.width + spacing) * CGFloat(col), y: 8.0 + (grid.cell.height + spacing) * CGFloat(row), width: grid.cell.width, height: grid.cell.height)
                }
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
