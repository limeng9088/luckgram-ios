import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import TextFormat
import LuckgramDiscover

// Square feed (spec 26, luckgram-specs#64). Same flow and texts as SquareActivity on Android:
// "Latest" / "Popular" / "For you" in the title control, 20 posts per page with a cursor, pull
// down past the top to refresh, "New post" on the right. Browsing needs no link; writes go
// through LuckgramSquare.requireLink / requireProfile.
//
// The list is never emptied to reload. A refresh keeps the posts on screen under a spinning
// indicator and swaps the new page in when it has arrived; a failure leaves everything as it
// was. Each tab keeps its own list and position (SquareLogic.Feed); further pages load by
// themselves shortly before the end; what other Square pages changed (a like, a comment, a
// deleted post) is applied in place when the feed is shown again.

final class SquareFeedArguments {
    let openAuthor: (Int) -> Void
    let openPost: (Int) -> Void
    let openVideo: (Int) -> Void
    let more: (Int) -> Void
    let loadMore: () -> Void
    let retry: () -> Void

    init(openAuthor: @escaping (Int) -> Void, openPost: @escaping (Int) -> Void, openVideo: @escaping (Int) -> Void, more: @escaping (Int) -> Void, loadMore: @escaping () -> Void, retry: @escaping () -> Void) {
        self.openAuthor = openAuthor
        self.openPost = openPost
        self.openVideo = openVideo
        self.more = more
        self.loadMore = loadMore
        self.retry = retry
    }
}

/// Rows of one post: author, text, images, "♡ n · 💬 n" (tap = menu). Shared by the feed, the
/// author page and the post page.
enum LuckgramSquarePostEntry: ItemListNodeEntry {
    case author(Int32, Int, String, String, UIImage?)
    case hidden(Int32, Int, String)
    case text(Int32, Int, String, Bool)
    case images(Int32, Int, [SquareLogic.Image])
    case video(Int32, Int, SquareLogic.Video)
    case stats(Int32, Int, String, String)
    case footer(Int32, Int, String, Int)
    case action(Int32, Int, String, Int)

    var section: ItemListSectionId {
        switch self {
        case let .author(s, _, _, _, _), let .hidden(s, _, _), let .text(s, _, _, _), let .images(s, _, _), let .video(s, _, _), let .stats(s, _, _, _), let .footer(s, _, _, _), let .action(s, _, _, _):
            return s
        }
    }

    var stableId: Int64 {
        let kind: Int64
        let index: Int
        switch self {
        case let .author(_, i, _, _, _): kind = 0; index = i
        case let .hidden(_, i, _): kind = 1; index = i
        case let .text(_, i, _, _): kind = 2; index = i
        case let .images(_, i, _): kind = 3; index = i
        case let .video(_, i, _): kind = 3; index = i
        case let .stats(_, i, _, _): kind = 4; index = i
        case let .footer(_, i, _, _): kind = 5; index = i
        case let .action(_, i, _, _): kind = 6; index = i
        }
        return Int64(index) * 10 + kind
    }

    static func == (lhs: LuckgramSquarePostEntry, rhs: LuckgramSquarePostEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.author(a1, a2, a3, a4, a5), .author(b1, b2, b3, b4, b5)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 === b5
        case let (.hidden(a1, a2, a3), .hidden(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.video(a1, a2, a3), .video(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.text(a1, a2, a3, a4), .text(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.images(a1, a2, a3), .images(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.stats(a1, a2, a3, a4), .stats(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.footer(a1, a2, a3, a4), .footer(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.action(a1, a2, a3, a4), .action(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        default:
            return false
        }
    }

    static func < (lhs: LuckgramSquarePostEntry, rhs: LuckgramSquarePostEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SquareFeedArguments
        switch self {
        case let .author(_, index, name, sub, avatar):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: avatar, title: name, label: sub, labelStyle: .detailText, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openAuthor(index)
            })
        case let .hidden(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .text(_, index, text, full):
            return ItemListMultilineTextItem(presentationData: presentationData, text: text, enabledEntityTypes: [.allUrl, .mention, .hashtag], sectionId: self.section, style: .blocks, action: full ? nil : {
                arguments.openPost(index)
            }, longTapAction: {
                arguments.more(index)
            })
        case let .images(_, index, images):
            return LuckgramSquareImagesItem(presentationData: presentationData, images: images, sectionId: self.section, style: .blocks, action: {
                arguments.openPost(index)
            })
        case let .video(_, index, video):
            return LuckgramSquareVideoItem(presentationData: presentationData, video: video, sectionId: self.section, style: .blocks, action: {
                arguments.openVideo(index)
            })
        case let .stats(_, index, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.more(index)
            })
        case let .footer(_, _, text, _):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .action(_, _, title, id):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                if id == 1 {
                    arguments.loadMore()
                } else {
                    arguments.retry()
                }
            })
        }
    }

    /// The rows of `post` as section `section`, `index` being the post's position in the page.
    static func rows(for post: SquareLogic.Post, index: Int, section: Int32, avatar: UIImage?, full: Bool) -> [LuckgramSquarePostEntry] {
        let tx = LuckgramSquare.texts
        var e: [LuckgramSquarePostEntry] = []
        e.append(.author(section, index, post.author.displayName, LuckgramSquare.timeLine(post), avatar))
        if post.isHidden {
            e.append(.hidden(section, index, tx.hiddenInfo(post.hiddenReason)))
        }
        if !post.text.isEmpty {
            let text = full ? post.text : String(post.text.prefix(600))
            e.append(.text(section, index, text, full))
        }
        if let video = post.video {
            e.append(.video(section, index, video))
        } else if !post.images.isEmpty {
            e.append(.images(section, index, post.images))
        }
        e.append(.stats(section, index, (post.liked ? "♥ " : "♡ ") + tx.likes(post.likeCount) + "   💬 " + tx.comments(post.commentCount), tx.more))
        return e
    }
}

/// Avatars of the authors on a page, loaded once and cached by author id.
final class LuckgramSquareAvatars {
    private(set) var images: [String: UIImage] = [:]
    private var loading = Set<String>()
    private let disposables = DisposableSet()
    var updated: (() -> Void)?

    deinit {
        self.disposables.dispose()
    }

    func image(for author: SquareLogic.Author) -> UIImage? {
        if let i = self.images[author.id] {
            return i
        }
        let placeholder = LuckgramSquare.avatar(author: author, image: nil)
        if let url = author.avatarUrl, !self.loading.contains(author.id) {
            self.loading.insert(author.id)
            self.disposables.add(LuckgramSquare.image(url: url).start(next: { [weak self] image in
                guard let self, let image else {
                    return
                }
                self.images[author.id] = LuckgramSquare.avatar(author: author, image: image)
                self.updated?()
            }))
        }
        return placeholder
    }
}

private final class SquareFeedState {
    /// One list per tab, kept while the page is open.
    var feeds: [String: SquareLogic.Feed] = [:]
    var feed: SquareLogic.Feed
    /// specs#115: impressions / views per tab; a refresh starts a new one (once per load).
    var trackers: [String: SquareEvents.Tracker] = [:]
    /// The list is pulled past the threshold with the finger still down.
    var armed = false
    /// The post to bring to the top once the list has its new rows (tab change, refresh).
    var pendingScrollToPost: Int?
    let avatars = LuckgramSquareAvatars()

    init() {
        let f = SquareLogic.Feed(tab: SquareLogic.tabLatest)
        self.feed = f
        self.feeds[f.tab] = f
    }

    func feed(for tab: String) -> SquareLogic.Feed {
        if let f = self.feeds[tab] {
            return f
        }
        let f = SquareLogic.Feed(tab: tab)
        self.feeds[tab] = f
        return f
    }

    func tracker(for feed: SquareLogic.Feed) -> SquareEvents.Tracker {
        if let t = self.trackers[feed.tab] {
            return t
        }
        let t = SquareEvents.Tracker(tab: feed.tab)
        self.trackers[feed.tab] = t
        return t
    }
}

/// specs#115: 最新 / 热门 / 推荐 (default stays 最新).
private let squareTabOrder = [SquareLogic.tabLatest, SquareLogic.tabHot, SquareLogic.tabRecommend]
/// How far the list is pulled past its top before a release refreshes it.
private let squarePullThreshold: CGFloat = 72.0

public func luckgramSquareController(context: AccountContext) -> ViewController {
    let tx = LuckgramSquare.texts
    let state = SquareFeedState()
    LuckgramSquare.pending = LuckgramSquare.PendingChanges()
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    func redraw() {
        version += 1
        updated.set(version)
    }
    state.avatars.updated = { redraw() }

    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    let present: (ViewController) -> Void = { presentImpl?($0) }
    let push: (ViewController) -> Void = { pushImpl?($0) }
    let refreshRequests = DisposableDict<String>()
    let moreRequests = DisposableDict<String>()
    let requests = DisposableSet()
    var refreshView: LuckgramSquareRefreshView?

    /// Loads the first page of `f`. Its posts stay on screen meanwhile and are replaced in one
    /// step when the page arrives; on failure nothing changes.
    func refreshFeed(_ f: SquareLogic.Feed) {
        guard f.beginRefresh() else {
            return
        }
        moreRequests.set(nil, forKey: f.tab)
        f.loadingMore = false
        let hadList = f.loadedOnce && !f.posts.isEmpty
        if f === state.feed {
            // an empty tab shows the page's loading state instead of the indicator
            if !f.posts.isEmpty {
                refreshView?.showRefreshing()
            } else {
                refreshView?.finish(result: nil)
            }
            redraw()
        }
        refreshRequests.set(LuckgramAI.shared.requestJSON(method: "GET", path: SquareLogic.feedPath(tab: f.tab, cursor: nil)).start(next: { j in
            // a new load: impressions count again (contract: once per load)
            LuckgramSquareEvents.add(state.tracker(for: f).hideAll(now: SquareEvents.nowMs()))
            state.trackers[f.tab] = nil
            let fresh = f.applyRefresh(SquareLogic.parsePosts(j), now: SquareEvents.nowMs())
            guard f === state.feed else {
                return
            }
            state.pendingScrollToPost = 0
            redraw()
            refreshView?.finish(result: hadList ? tx.refreshed(fresh) : nil)
        }, error: { error in
            f.failRefresh()
            guard f === state.feed else {
                return
            }
            redraw()
            refreshView?.finish(result: nil)
            // the list (if any) is still there; say why it did not update
            LuckgramSquare.showError(error, context: context, present: present, push: push)
        }), forKey: f.tab)
    }

    /// Pull down past the top: refresh, then say what came.
    func refreshByUser() {
        let f = state.feed
        if f.refreshing {
            if !f.posts.isEmpty {
                refreshView?.showRefreshing()
            }
            return
        }
        refreshFeed(f)
    }

    /// The next page, requested a few posts before the end so the reader rarely sees it load.
    func loadMore(_ f: SquareLogic.Feed) {
        guard f.canLoadMore else {
            return
        }
        let generation = f.beginMore()
        if f === state.feed {
            redraw()
        }
        moreRequests.set(LuckgramAI.shared.requestJSON(method: "GET", path: SquareLogic.feedPath(tab: f.tab, cursor: f.nextCursor)).start(next: { j in
            if f.applyMore(SquareLogic.parsePosts(j), generation: generation), f === state.feed {
                redraw()
            }
        }, error: { _ in
            // quiet: the footer turns into "tap to retry"
            f.failMore(generation: generation)
            if f === state.feed {
                redraw()
            }
        }), forKey: f.tab)
    }

    let arguments = SquareFeedArguments(openAuthor: { index in
        guard index < state.feed.posts.count else {
            return
        }
        push(luckgramSquareAuthorController(context: context, author: state.feed.posts[index].author))
    }, openPost: { index in
        guard index < state.feed.posts.count else {
            return
        }
        LuckgramSquareEvents.add(type: SquareEvents.open, postId: state.feed.posts[index].id, tab: state.feed.tab, rank: index)
        push(luckgramSquarePostController(context: context, post: state.feed.posts[index]))
    }, openVideo: { index in
        guard index < state.feed.posts.count, let video = state.feed.posts[index].video else {
            return
        }
        LuckgramSquareVideoPlayer.present(video, context: context, fallback: nil)
    }, more: { index in
        guard index < state.feed.posts.count else {
            return
        }
        let post = state.feed.posts[index]
        let tab = state.feed.tab
        LuckgramSquare.showPostMenu(context: context, post: post, present: present, push: push, onLiked: { p in
            for f in state.feeds.values {
                f.mergeSilently([p])
            }
            redraw()
        }, onComment: {
            push(luckgramSquarePostController(context: context, post: post))
        }, onDeleted: {
            for f in state.feeds.values {
                f.removePost(post.id)
            }
            redraw()
        }, onBlocked: {
            for f in state.feeds.values {
                f.removeAuthor(post.author.id)
            }
            redraw()
        }, onNotInterested: tab == SquareLogic.tabRecommend ? {
            // specs#115: removed at once, server stops recommending it
            LuckgramSquareEvents.add(type: SquareEvents.notInterested, postId: post.id, tab: tab, rank: index)
            state.feed(for: tab).removePost(post.id)
            redraw()
        } : nil)
    }, loadMore: {
        loadMore(state.feed)
    }, retry: {
        refreshFeed(state.feed)
    })

    let entries = updated.get() |> map { _ -> [LuckgramSquarePostEntry] in
        let f = state.feed
        var e: [LuckgramSquarePostEntry] = []
        for (i, post) in f.posts.enumerated() {
            e.append(contentsOf: LuckgramSquarePostEntry.rows(for: post, index: i, section: Int32(i + 1), avatar: state.avatars.image(for: post.author), full: false))
        }
        let tail = Int32(f.posts.count + 1)
        let tailIndex = f.posts.count
        switch f.footer {
        case .skeleton:
            // first load: the page shows its loading state
            break
        case .firstError:
            e.append(.footer(tail, tailIndex, tx.loadFailed, 0))
            e.append(.action(tail, tailIndex, tx.retry, 2))
        case .empty:
            e.append(.footer(tail, tailIndex, tx.empty, 0))
        case .loadingMore:
            e.append(.footer(tail, tailIndex, tx.loading, 0))
        case .moreError:
            e.append(.action(tail, tailIndex, tx.moreFailed, 1))
        case .end:
            e.append(.footer(tail, tailIndex, tx.noMore, 0))
        }
        return e
    }

    let signal = combineLatest(context.sharedContext.presentationData, entries)
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightButton = ItemListNavigationButton(content: .text(tx.compose), style: .bold, enabled: true, action: {
            let d = LuckgramSquare.requireProfile(context: context, present: present, push: push, then: {
                push(luckgramSquareComposeController(context: context))
            })
            requests.add(d)
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .sectionControl([tx.latest, tx.hot, tx.recommend], squareTabOrder.firstIndex(of: state.feed.tab) ?? 0), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let loadingFirstPage = entries.isEmpty && state.feed.footer == .skeleton
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: loadingFirstPage ? ItemListLoadingIndicatorEmptyStateItem(theme: presentationData.theme) : nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    controller.titleControlValueChanged = { index in
        let next = squareTabOrder[max(0, min(squareTabOrder.count - 1, index))]
        if next == state.feed.tab {
            return
        }
        // leave the old tab as it is; come back to the post that was on screen
        LuckgramSquareEvents.add(state.tracker(for: state.feed).hideAll(now: SquareEvents.nowMs()))
        let f = state.feed(for: next)
        state.feed = f
        state.armed = false
        state.pendingScrollToPost = f.scrollIndex
        if f.refreshing && !f.posts.isEmpty {
            refreshView?.showRefreshing()
        } else {
            refreshView?.finish(result: nil)
        }
        redraw()
        if f.isStale(now: SquareEvents.nowMs()) {
            refreshFeed(f)
        }
    }
    controller.afterTransactionCompleted = { [weak controller] in
        guard let post = state.pendingScrollToPost, let node = controller?.displayNode as? ItemListControllerNode else {
            return
        }
        state.pendingScrollToPost = nil
        let posts = state.feed.posts
        guard post < posts.count else {
            return
        }
        // rows above the post
        var index = 0
        for p in posts.prefix(post) {
            index += LuckgramSquarePostEntry.rows(for: p, index: 0, section: 0, avatar: nil, full: false).count
        }
        node.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: ListViewScrollToItem(index: index, position: .top(0.0), animated: false, curve: .Default(duration: nil), directionHint: .Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
    }
    controller.visibleBottomContentOffsetChanged = { offset in
        let f = state.feed
        if case let .known(value) = offset, value < 300.0, f.canLoadMore, !f.moreFailed {
            loadMore(f)
        }
    }
    // specs#115: posts with a row on screen → impressions; leaving the screen → views with dwell
    controller.visibleEntriesUpdated = { entries in
        let f = state.feed
        var visible: [String: Int] = [:]
        var first: Int?
        var last = -1
        for entry in entries {
            guard let entry = entry as? LuckgramSquarePostEntry else {
                continue
            }
            switch entry {
            case let .text(_, i, _, _), let .images(_, i, _), let .video(_, i, _), let .hidden(_, i, _):
                if i < f.posts.count {
                    visible[f.posts[i].id] = i
                    first = min(first ?? i, i)
                    last = max(last, i)
                }
            default:
                break
            }
        }
        LuckgramSquareEvents.add(state.tracker(for: f).update(visible: visible, now: SquareEvents.nowMs()))
        if state.pendingScrollToPost == nil, let first {
            f.scrollIndex = first
        }
        if f.shouldLoadMore(lastVisiblePost: last) {
            loadMore(f)
        }
    }
    controller.didDisappear = { _ in
        LuckgramSquareEvents.add(state.tracker(for: state.feed).hideAll(now: SquareEvents.nowMs()))
        LuckgramSquareEvents.flush(force: true)
    }
    var pullInstalled = false
    controller.didAppear = { [weak controller] _ in
        // What other Square pages did while this one was covered: applied in place, the list
        // stays where it is. Only a new post brings it back to the top to refresh.
        let pending = LuckgramSquare.pending
        LuckgramSquare.pending = LuckgramSquare.PendingChanges()
        var changed = false
        let updatedPosts = Array(pending.updated.values)
        for f in state.feeds.values {
            if !updatedPosts.isEmpty && f.mergeSilently(updatedPosts) > 0 {
                changed = true
            }
            for id in pending.removedPosts where f.removePost(id) {
                changed = true
            }
            for id in pending.blockedAuthors where f.removeAuthor(id) > 0 {
                changed = true
            }
        }
        if changed {
            redraw()
        }
        if pending.needsRefresh {
            for f in state.feeds.values {
                f.loadedAtMs = 0
            }
            refreshByUser()
        }

        guard !pullInstalled, let controller, let node = controller.displayNode as? ItemListControllerNode else {
            return
        }
        pullInstalled = true
        // Pull down past the top to refresh (spec 26 item 2): an indicator follows the pull and
        // the refresh starts on release.
        let view = LuckgramSquareRefreshView(theme: context.sharedContext.currentPresentationData.with { $0 }.theme)
        refreshView = view
        node.view.addSubview(view)
        let layoutRefreshView: () -> Void = { [weak node, weak view] in
            guard let node, let view else {
                return
            }
            let frame = CGRect(x: 0.0, y: node.listNode.insets.top, width: node.bounds.width, height: LuckgramSquareRefreshView.height)
            if view.frame != frame {
                view.frame = frame
            }
        }
        layoutRefreshView()
        if state.feed.refreshing && !state.feed.posts.isEmpty {
            view.showRefreshing()
        }
        let previous = node.listNode.visibleContentOffsetChanged
        node.listNode.visibleContentOffsetChanged = { [weak node, weak view] offset, transition in
            previous(offset, transition)
            layoutRefreshView()
            guard let node, let view, case let .known(value) = offset else {
                return
            }
            if state.feed.refreshing || view.isRefreshing {
                return
            }
            let pull = max(0.0, -value)
            if node.listNode.scroller.isTracking {
                let nowArmed = pull >= squarePullThreshold
                if nowArmed && !state.armed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                state.armed = nowArmed
                view.setPull(pull / squarePullThreshold)
            } else if state.armed {
                // released past the threshold
                state.armed = false
                refreshByUser()
            } else {
                view.setPull(pull / squarePullThreshold)
            }
        }
    }
    requests.add(ActionDisposable {
        refreshRequests.dispose()
        moreRequests.dispose()
    })
    LuckgramSquare.prefetchMe()
    refreshFeed(state.feed)
    return controller
}
