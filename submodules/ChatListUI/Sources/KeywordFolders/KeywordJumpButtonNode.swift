// Luckgram — keyword folders: "Next 'invoice'" pill shown above the input panel when a chat is
// opened from a keyword folder. Each tap scrolls to the next older cached message with a keyword.

import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import UndoUI

public final class KeywordJumpButtonNode: ASDisplayNode {
    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let keywords: [String]
    private let jump: (EngineMessage.Id) -> Void
    private let presentController: (ViewController) -> Void

    private let backgroundNode: ASImageNode
    private let buttonNode: HighlightableButtonNode
    private let textNode: ImmediateTextNode
    private let closeButtonNode: HighlightableButtonNode

    private var presentationData: PresentationData
    private var hits: [(EngineMessage.Id, String)] = []
    private var lastJumpedId: EngineMessage.Id?
    private var isDismissed = false
    private var isLoading = false
    private let disposable = MetaDisposable()

    /// Called when the size or visibility changed and the container must lay out again.
    public var requestLayout: (() -> Void)?

    public var isVisible: Bool {
        return !self.isDismissed && !self.hits.isEmpty
    }

    /// The folder's keywords when `chatListFilterId` is a keyword folder of this account, else nil.
    public static func keywords(context: AccountContext, chatListFilterId: Int32?) -> [String]? {
        guard let folder = cachedKeywordFolder(accountPeerId: context.account.peerId, filterId: chatListFilterId), !folder.keywords.isEmpty else {
            return nil
        }
        return folder.keywords
    }

    public init(context: AccountContext, peerId: EnginePeer.Id, keywords: [String], jump: @escaping (EngineMessage.Id) -> Void, presentController: @escaping (ViewController) -> Void) {
        self.context = context
        self.peerId = peerId
        self.keywords = keywords
        self.jump = jump
        self.presentController = presentController
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        self.backgroundNode = ASImageNode()
        self.backgroundNode.displaysAsynchronously = false
        self.backgroundNode.displayWithoutProcessing = true

        self.buttonNode = HighlightableButtonNode()
        self.textNode = ImmediateTextNode()
        self.textNode.displaysAsynchronously = false
        self.textNode.maximumNumberOfLines = 1
        self.textNode.isUserInteractionEnabled = false

        self.closeButtonNode = HighlightableButtonNode()

        super.init()

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.buttonNode)
        self.buttonNode.addSubnode(self.textNode)
        self.addSubnode(self.closeButtonNode)

        self.buttonNode.addTarget(self, action: #selector(self.jumpPressed), forControlEvents: .touchUpInside)
        self.closeButtonNode.addTarget(self, action: #selector(self.closePressed), forControlEvents: .touchUpInside)

        self.applyTheme()
        self.reload(jump: false)
    }

    deinit {
        self.disposable.dispose()
    }

    private func applyTheme() {
        let theme = self.presentationData.theme
        self.backgroundNode.image = generateStretchableFilledCircleImage(diameter: 36.0, color: theme.list.itemBlocksBackgroundColor, strokeColor: theme.list.itemBlocksSeparatorColor, strokeWidth: UIScreenPixel)
        let closeColor = theme.list.itemSecondaryTextColor
        self.closeButtonNode.setImage(generateImage(CGSize(width: 10.0, height: 10.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setStrokeColor(closeColor.cgColor)
            context.setLineWidth(1.66)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: 1.0, y: 1.0))
            context.addLine(to: CGPoint(x: size.width - 1.0, y: size.height - 1.0))
            context.move(to: CGPoint(x: size.width - 1.0, y: 1.0))
            context.addLine(to: CGPoint(x: 1.0, y: size.height - 1.0))
            context.strokePath()
        }), for: .normal)
        self.closeButtonNode.accessibilityLabel = self.presentationData.strings.Common_Close
        self.updateText()
    }

    private func nextIndex() -> Int {
        guard let lastJumpedId = self.lastJumpedId, let index = self.hits.firstIndex(where: { $0.0 == lastJumpedId }) else {
            return 0
        }
        return index + 1 < self.hits.count ? index + 1 : 0
    }

    private func updateText() {
        let keyword: String
        if self.hits.isEmpty {
            keyword = self.keywords.first ?? ""
        } else {
            keyword = self.hits[self.nextIndex()].1
        }
        let text = KeywordFolderStrings.jumpNext(self.presentationData.strings, keyword)
        self.textNode.attributedText = NSAttributedString(string: text, font: Font.medium(14.0), textColor: self.presentationData.theme.list.itemAccentColor)
        self.buttonNode.accessibilityLabel = text
    }

    private func reload(jump: Bool) {
        if self.isLoading {
            return
        }
        self.isLoading = true
        self.disposable.set((keywordFolderHits(context: self.context, peerId: self.peerId, keywords: self.keywords)
        |> deliverOnMainQueue).startStrict(next: { [weak self] hits in
            guard let self else {
                return
            }
            self.isLoading = false
            self.hits = hits
            if jump {
                self.performJump()
            }
            self.updateText()
            self.requestLayout?()
        }))
    }

    private func performJump() {
        let strings = self.presentationData.strings
        if self.hits.isEmpty {
            self.presentController(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: KeywordFolderStrings.jumpNone(strings), timeout: nil, customUndoText: nil), elevatedLayout: true, action: { _ in return false }))
            return
        }
        var wrapped = false
        if let lastJumpedId = self.lastJumpedId, let index = self.hits.firstIndex(where: { $0.0 == lastJumpedId }), index + 1 >= self.hits.count {
            wrapped = true
        }
        let target = self.hits[self.nextIndex()].0
        self.lastJumpedId = target
        if wrapped {
            self.presentController(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: KeywordFolderStrings.jumpNoMore(strings), timeout: nil, customUndoText: nil), elevatedLayout: true, action: { _ in return false }))
        }
        self.jump(target)
    }

    @objc private func jumpPressed() {
        self.reload(jump: true)
    }

    @objc private func closePressed() {
        self.isDismissed = true
        self.requestLayout?()
    }

    public func updatePresentationData(_ presentationData: PresentationData) {
        if self.presentationData.theme !== presentationData.theme || self.presentationData.strings !== presentationData.strings {
            self.presentationData = presentationData
            self.applyTheme()
        }
    }

    /// Lays out the pill and returns its size.
    public func updateLayout(maxWidth: CGFloat) -> CGSize {
        let height: CGFloat = 36.0
        let closeWidth: CGFloat = 32.0
        let textSize = self.textNode.updateLayout(CGSize(width: max(40.0, maxWidth - closeWidth - 28.0), height: height))
        let buttonWidth = textSize.width + 28.0
        let size = CGSize(width: buttonWidth + closeWidth, height: height)
        self.backgroundNode.frame = CGRect(origin: CGPoint(), size: size)
        self.buttonNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: buttonWidth, height: height))
        self.textNode.frame = CGRect(origin: CGPoint(x: 16.0, y: floor((height - textSize.height) / 2.0)), size: textSize)
        self.closeButtonNode.frame = CGRect(origin: CGPoint(x: buttonWidth - 6.0, y: 0.0), size: CGSize(width: closeWidth, height: height))
        return size
    }
}
