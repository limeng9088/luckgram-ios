// Luckgram — "Activity" pane on user profiles (spec 16): what this user recently wrote in the
// groups you share with them. Telegram only: groups in common (all pages, groups you are in),
// then messages.search(from_id) with 20 per group, at most 3 searches at a time (TelegramCore's
// network layer sits out FLOOD_WAIT and retries). Merged newest first, at most 100, cached 10
// minutes per user. Same rules and wording as Android `SharedActivityLoader`.

import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import ItemListUI
import MergeLists
import ChatControllerInteraction
import PeerInfoPaneNode
import LuckgramUI
import LuckgramSharedActivity

enum LuckgramActivityPane {
    static let settingKey = "shared_activity"

    static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(settingKey)
    }

    static var tabTitle: String { LuckgramStrings.pick("动态", "Activity") }
    static var refreshText: String { LuckgramStrings.pick("刷新", "Refresh") }
    static var loadingText: String { LuckgramStrings.pick("正在加载…", "Loading…") }
    static var emptyNoGroups: String { LuckgramStrings.pick("你们没有共同群组", "You have no groups in common") }
    static var emptyNoMessages: String { LuckgramStrings.pick("最近没有在共同群组里发过消息", "No recent messages in your groups in common") }
    static var mediaText: String { LuckgramStrings.pick("[媒体]", "[Media]") }

    static func header(groupCount: Int) -> String {
        return LuckgramSharedActivityLogic.header(groupCount: groupCount, chinese: LuckgramStrings.isChinese)
    }

    struct Result {
        let messages: [EngineMessage]
        let groupCount: Int
        let loadedAt: Double
    }

    /// Main thread only.
    private static var cache: [String: Result] = [:]

    private static func cacheKey(context: AccountContext, userId: EnginePeer.Id) -> String {
        return "\(context.account.peerId.toInt64()):\(userId.toInt64())"
    }

    static func cached(context: AccountContext, userId: EnginePeer.Id) -> Result? {
        guard let result = cache[cacheKey(context: context, userId: userId)] else {
            return nil
        }
        return LuckgramSharedActivityLogic.isFresh(loadedAt: result.loadedAt, now: CFAbsoluteTimeGetCurrent()) ? result : nil
    }

    static func store(_ result: Result, context: AccountContext, userId: EnginePeer.Id) {
        cache[cacheKey(context: context, userId: userId)] = result
    }

    /// Every group in common that you are a member of (all pages).
    private static func commonGroups(context: AccountContext, userId: EnginePeer.Id) -> Signal<[EnginePeer], NoError> {
        return Signal { subscriber in
            let groupsContext = GroupsInCommonContext(account: context.account, peerId: userId)
            // Ask for the next page once per page (the state repeats while a page loads).
            var requestedAtCount = -1
            let disposable = (groupsContext.state
            |> deliverOnMainQueue).startStrict(next: { state in
                guard case let .ready(canLoadMore) = state.dataState else {
                    return
                }
                if canLoadMore {
                    if state.peers.count != requestedAtCount {
                        requestedAtCount = state.peers.count
                        groupsContext.loadMore()
                    }
                    return
                }
                var groups: [EnginePeer] = []
                for rendered in state.peers {
                    guard let peer = rendered.peer else {
                        continue
                    }
                    if let group = peer as? TelegramGroup, case .Member = group.membership {
                        groups.append(EnginePeer(group))
                    } else if let channel = peer as? TelegramChannel, case .group = channel.info, case .member = channel.participationStatus {
                        groups.append(EnginePeer(channel))
                    }
                }
                subscriber.putNext(groups)
                subscriber.putCompletion()
            })
            return ActionDisposable {
                disposable.dispose()
                let _ = groupsContext
            }
        }
    }

    private static func recentMessages(context: AccountContext, groupId: EnginePeer.Id, userId: EnginePeer.Id) -> Signal<[EngineMessage], NoError> {
        let location: SearchMessagesLocation = .peer(peerId: groupId, fromId: userId, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil)
        return context.engine.messages.searchMessages(location: location, query: "", state: nil, limit: Int32(LuckgramSharedActivityLogic.perGroup))
        |> take(1)
        |> map { result, _ -> [EngineMessage] in
            return result.messages.compactMap { message -> EngineMessage? in
                if message.media.contains(where: { $0 is TelegramMediaAction }) {
                    return nil
                }
                return EngineMessage(message)
            }
        }
    }

    static func load(context: AccountContext, userId: EnginePeer.Id) -> Signal<Result, NoError> {
        return commonGroups(context: context, userId: userId)
        |> mapToSignal { groups -> Signal<Result, NoError> in
            // Batches of at most `maxParallel` searches, one batch after another.
            var batches: [[EnginePeer]] = []
            var index = 0
            while index < groups.count {
                batches.append(Array(groups[index ..< min(groups.count, index + LuckgramSharedActivityLogic.maxParallel)]))
                index += LuckgramSharedActivityLogic.maxParallel
            }
            var signal: Signal<[[EngineMessage]], NoError> = .single([])
            for batch in batches {
                signal = signal
                |> mapToSignal { collected -> Signal<[[EngineMessage]], NoError> in
                    return combineLatest(batch.map { recentMessages(context: context, groupId: $0.id, userId: userId) })
                    |> take(1)
                    |> map { collected + $0 }
                }
            }
            return signal
            |> map { perGroup -> Result in
                let merged = LuckgramSharedActivityLogic.newestFirst(perGroup, limit: LuckgramSharedActivityLogic.maxItems, date: { $0.timestamp }, id: { Int64($0.id.id) })
                return Result(messages: merged, groupCount: groups.count, loadedAt: CFAbsoluteTimeGetCurrent())
            }
        }
        |> deliverOnMainQueue
    }
}

private enum LuckgramActivityEntryId: Hashable {
    case header
    case status
    case message(EngineMessage.Id)
}

private enum LuckgramActivityEntry: Comparable, Identifiable {
    case header(title: String, canRefresh: Bool)
    case status(String)
    case message(index: Int, id: EngineMessage.Id, group: EnginePeer, time: String, preview: String)

    var stableId: LuckgramActivityEntryId {
        switch self {
        case .header:
            return .header
        case .status:
            return .status
        case let .message(_, id, _, _, _):
            return .message(id)
        }
    }

    private var sortIndex: Int {
        switch self {
        case .header:
            return 0
        case .status:
            return 1
        case let .message(index, _, _, _, _):
            return 2 + index
        }
    }

    static func ==(lhs: LuckgramActivityEntry, rhs: LuckgramActivityEntry) -> Bool {
        switch lhs {
        case let .header(title, canRefresh):
            if case .header(title, canRefresh) = rhs {
                return true
            }
            return false
        case let .status(text):
            if case .status(text) = rhs {
                return true
            }
            return false
        case let .message(index, id, group, time, preview):
            if case let .message(rIndex, rId, rGroup, rTime, rPreview) = rhs {
                return index == rIndex && id == rId && group == rGroup && time == rTime && preview == rPreview
            }
            return false
        }
    }

    static func <(lhs: LuckgramActivityEntry, rhs: LuckgramActivityEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(context: AccountContext, presentationData: PresentationData, refresh: @escaping () -> Void, open: @escaping (EnginePeer, EngineMessage.Id) -> Void) -> ListViewItem {
        let itemPresentationData = ItemListPresentationData(presentationData)
        switch self {
        case let .header(title, canRefresh):
            return ItemListDisclosureItem(presentationData: itemPresentationData, title: title, label: canRefresh ? LuckgramActivityPane.refreshText : "", sectionId: 0, style: .plain, disclosureStyle: .none, noInsets: true, action: canRefresh ? refresh : nil)
        case let .status(text):
            return ItemListDisclosureItem(presentationData: itemPresentationData, title: text, enabled: false, label: "", sectionId: 0, style: .plain, disclosureStyle: .none, noInsets: true, action: nil)
        case let .message(_, id, group, time, preview):
            return ItemListDisclosureItem(presentationData: itemPresentationData, context: context, iconPeer: group, title: group.compactDisplayTitle, label: time, additionalDetailLabel: preview, sectionId: 0, style: .plain, disclosureStyle: .none, noInsets: true, action: {
                open(group, id)
            })
        }
    }
}

private struct LuckgramActivityTransaction {
    let deletions: [ListViewDeleteItem]
    let insertions: [ListViewInsertItem]
    let updates: [ListViewUpdateItem]
}

final class PeerInfoLuckgramActivityPaneNode: ASDisplayNode, PeerInfoPaneNode {
    private let context: AccountContext
    private let userId: EnginePeer.Id
    private let chatControllerInteraction: ChatControllerInteraction

    weak var parentController: ViewController?

    private let listNode: ListView
    private var currentEntries: [LuckgramActivityEntry] = []
    private var enqueuedTransactions: [LuckgramActivityTransaction] = []
    private var currentParams: (size: CGSize, isScrollingLockedAtTop: Bool, presentationData: PresentationData)?

    private var result: LuckgramActivityPane.Result?
    private var isLoading = false
    private let loadDisposable = MetaDisposable()
    private let statusPromise = Promise<PeerInfoStatusData?>(nil)

    private let ready = Promise<Bool>()
    private var didSetReady = false
    var isReady: Signal<Bool, NoError> {
        return self.ready.get()
    }

    var status: Signal<PeerInfoStatusData?, NoError> {
        return self.statusPromise.get()
    }

    var tabBarOffsetUpdated: ((ContainedViewLayoutTransition) -> Void)?
    var tabBarOffset: CGFloat {
        return 0.0
    }

    init(context: AccountContext, userId: EnginePeer.Id, chatControllerInteraction: ChatControllerInteraction) {
        self.context = context
        self.userId = userId
        self.chatControllerInteraction = chatControllerInteraction
        self.listNode = ListViewImpl()

        super.init()

        self.addSubnode(self.listNode)
        self.load(force: false)
    }

    deinit {
        self.loadDisposable.dispose()
    }

    private func load(force: Bool) {
        if !force, let cached = LuckgramActivityPane.cached(context: self.context, userId: self.userId) {
            self.result = cached
            self.isLoading = false
            self.updateEntries()
            return
        }
        self.isLoading = true
        self.updateEntries()
        let context = self.context
        let userId = self.userId
        self.loadDisposable.set((LuckgramActivityPane.load(context: context, userId: userId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] result in
            LuckgramActivityPane.store(result, context: context, userId: userId)
            guard let self else {
                return
            }
            self.result = result
            self.isLoading = false
            self.updateEntries()
        }))
    }

    private func updateEntries() {
        if let result = self.result {
            self.statusPromise.set(.single(PeerInfoStatusData(text: LuckgramActivityPane.header(groupCount: result.groupCount), isActivity: false, key: .luckgramActivity)))
        }
        guard let (_, _, presentationData) = self.currentParams else {
            return
        }
        var entries: [LuckgramActivityEntry] = []
        entries.append(.header(title: LuckgramActivityPane.header(groupCount: self.result?.groupCount ?? 0), canRefresh: !self.isLoading))
        if self.isLoading && self.result == nil {
            entries.append(.status(LuckgramActivityPane.loadingText))
        } else if let result = self.result {
            if result.messages.isEmpty {
                entries.append(.status(result.groupCount == 0 ? LuckgramActivityPane.emptyNoGroups : LuckgramActivityPane.emptyNoMessages))
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            for message in result.messages {
                guard let group = message.peers[message.id.peerId].flatMap(EnginePeer.init) else {
                    continue
                }
                let time = formatter.string(from: Date(timeIntervalSince1970: Double(message.timestamp)))
                var preview = message.text.replacingOccurrences(of: "\n", with: " ")
                if preview.isEmpty {
                    preview = LuckgramActivityPane.mediaText
                }
                entries.append(.message(index: entries.count, id: message.id, group: group, time: time, preview: preview))
            }
        }

        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: self.currentEntries, rightList: entries)
        let refresh: () -> Void = { [weak self] in
            self?.load(force: true)
        }
        let open: (EnginePeer, EngineMessage.Id) -> Void = { [weak self] group, messageId in
            self?.open(group: group, messageId: messageId)
        }
        let context = self.context
        let transaction = LuckgramActivityTransaction(
            deletions: deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) },
            insertions: indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(context: context, presentationData: presentationData, refresh: refresh, open: open), directionHint: nil) },
            updates: updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(context: context, presentationData: presentationData, refresh: refresh, open: open), directionHint: nil) }
        )
        self.currentEntries = entries
        self.enqueuedTransactions.append(transaction)
        self.dequeueTransaction()
    }

    private func open(group: EnginePeer, messageId: EngineMessage.Id) {
        guard let navigationController = self.chatControllerInteraction.navigationController() else {
            return
        }
        // Opens the group at that message and highlights it.
        self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(group), subject: .message(id: .id(messageId), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false), keepStack: .always))
    }

    private func dequeueTransaction() {
        guard let _ = self.currentParams, let transaction = self.enqueuedTransactions.first else {
            return
        }
        self.enqueuedTransactions.remove(at: 0)
        var options = ListViewDeleteAndInsertOptions()
        options.insert(.Synchronous)
        self.listNode.transaction(deleteIndices: transaction.deletions, insertIndicesAndItems: transaction.insertions, updateIndicesAndItems: transaction.updates, options: options, updateSizeAndInsets: nil, updateOpaqueState: nil, completion: { [weak self] _ in
            guard let self else {
                return
            }
            if !self.didSetReady {
                self.didSetReady = true
                self.ready.set(.single(true))
            }
        })
    }

    func ensureMessageIsVisible(id: EngineMessage.Id) {
    }

    func scrollToTop() -> Bool {
        if !self.listNode.scrollToOffsetFromTop(0.0, animated: true) {
            self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
            return true
        } else {
            return false
        }
    }

    func update(size: CGSize, topInset: CGFloat, sideInset: CGFloat, bottomInset: CGFloat, deviceMetrics: DeviceMetrics, visibleHeight: CGFloat, isScrollingLockedAtTop: Bool, expandProgress: CGFloat, navigationHeight: CGFloat, presentationData: PresentationData, synchronous: Bool, transition: ContainedViewLayoutTransition) {
        let isFirstLayout = self.currentParams == nil
        self.currentParams = (size, isScrollingLockedAtTop, presentationData)

        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)

        var scrollToItem: ListViewScrollToItem?
        if isScrollingLockedAtTop {
            switch self.listNode.visibleContentOffset() {
            case let .known(value) where value <= CGFloat.ulpOfOne:
                break
            default:
                scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Spring(duration: duration), directionHint: .Up)
            }
        }
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: scrollToItem, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: size, insets: UIEdgeInsets(top: topInset, left: sideInset, bottom: bottomInset, right: sideInset), duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
        self.listNode.scrollEnabled = !isScrollingLockedAtTop

        if isFirstLayout {
            self.updateEntries()
        }
    }

    func findLoadedMessage(id: EngineMessage.Id) -> EngineMessage? {
        return nil
    }

    func updateHiddenMedia() {
    }

    func transferVelocity(_ velocity: CGFloat) {
        if velocity > 0.0 {
            self.listNode.transferVelocity(velocity)
        }
    }

    func cancelPreviewGestures() {
    }

    func transitionNodeForGallery(messageId: EngineMessage.Id, media: EngineMedia) -> (ASDisplayNode, CGRect, () -> (UIView?, UIView?))? {
        return nil
    }

    func addToTransitionSurface(view: UIView) {
    }

    func updateSelectedMessages(animated: Bool) {
    }
}
