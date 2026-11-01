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
// "Latest" / "Popular" in the title control, 20 posts per page with a cursor, pull down past the
// top to refresh, "New post" on the right. Browsing needs no link; writes go through
// LuckgramSquare.requireLink / requireProfile.

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
    var tab = SquareLogic.tabLatest
    var posts: [SquareLogic.Post] = []
    var nextCursor: String?
    var loading = false
    var loadedOnce = false
    var failed = false
    var seenChange = 0
    var pullArmed = true
    let avatars = LuckgramSquareAvatars()
}

public func luckgramSquareController(context: AccountContext) -> ViewController {
    let tx = LuckgramSquare.texts
    let state = SquareFeedState()
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    func refresh() {
        version += 1
        updated.set(version)
    }
    state.avatars.updated = { refresh() }

    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    let present: (ViewController) -> Void = { presentImpl?($0) }
    let push: (ViewController) -> Void = { pushImpl?($0) }
    let listRequest = MetaDisposable()
    let requests = DisposableSet()

    func load(reset: Bool) {
        if reset {
            state.posts = []
            state.nextCursor = nil
            state.loadedOnce = false
        }
        state.loading = true
        state.failed = false
        refresh()
        let requestedTab = state.tab
        listRequest.set(LuckgramAI.shared.requestJSON(method: "GET", path: SquareLogic.feedPath(tab: state.tab, cursor: state.nextCursor)).start(next: { j in
            guard requestedTab == state.tab else {
                return
            }
            let page = SquareLogic.parsePosts(j)
            SquareLogic.appendUnique(&state.posts, page.items)
            state.nextCursor = page.nextCursor
            state.loading = false
            state.loadedOnce = true
            refresh()
        }, error: { error in
            state.loading = false
            state.failed = true
            refresh()
            LuckgramSquare.showError(error, context: context, present: present, push: push)
        }))
    }

    let arguments = SquareFeedArguments(openAuthor: { index in
        guard index < state.posts.count else {
            return
        }
        push(luckgramSquareAuthorController(context: context, author: state.posts[index].author))
    }, openPost: { index in
        guard index < state.posts.count else {
            return
        }
        push(luckgramSquarePostController(context: context, post: state.posts[index]))
    }, openVideo: { index in
        guard index < state.posts.count, let video = state.posts[index].video else {
            return
        }
        LuckgramSquareVideoPlayer.present(video, context: context, fallback: nil)
    }, more: { index in
        guard index < state.posts.count else {
            return
        }
        let post = state.posts[index]
        LuckgramSquare.showPostMenu(context: context, post: post, present: present, push: push, onLiked: { p in
            if let i = state.posts.firstIndex(where: { $0.id == p.id }) {
                state.posts[i] = p
                refresh()
            }
        }, onComment: {
            push(luckgramSquarePostController(context: context, post: post))
        }, onDeleted: {
            state.posts.removeAll(where: { $0.id == post.id })
            refresh()
        }, onBlocked: {
            state.posts.removeAll(where: { $0.author.id == post.author.id })
            refresh()
        })
    }, loadMore: {
        if !state.loading && state.nextCursor != nil {
            load(reset: false)
        }
    }, retry: {
        load(reset: state.posts.isEmpty)
    })

    let entries = updated.get() |> map { _ -> [LuckgramSquarePostEntry] in
        var e: [LuckgramSquarePostEntry] = []
        for (i, post) in state.posts.enumerated() {
            e.append(contentsOf: LuckgramSquarePostEntry.rows(for: post, index: i, section: Int32(i + 1), avatar: state.avatars.image(for: post.author), full: false))
        }
        let tail = Int32(state.posts.count + 1)
        let tailIndex = state.posts.count
        if state.loading {
            e.append(.footer(tail, tailIndex, tx.loading, 0))
        } else if state.failed {
            e.append(.action(tail, tailIndex, tx.refresh, 2))
        } else if state.loadedOnce && state.posts.isEmpty {
            e.append(.footer(tail, tailIndex, tx.empty, 0))
        } else if state.nextCursor != nil {
            e.append(.action(tail, tailIndex, tx.loadMore, 1))
        } else if !state.posts.isEmpty {
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
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .sectionControl([tx.latest, tx.hot], state.tab == SquareLogic.tabHot ? 1 : 0), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: nil, animateChanges: false)
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
        let next = index == 1 ? SquareLogic.tabHot : SquareLogic.tabLatest
        if next != state.tab {
            state.tab = next
            load(reset: true)
        }
    }
    controller.visibleBottomContentOffsetChanged = { offset in
        if case let .known(value) = offset, value < 300.0, !state.loading, state.nextCursor != nil, state.loadedOnce {
            load(reset: false)
        }
    }
    var pullInstalled = false
    controller.didAppear = { [weak controller] _ in
        // Reload when another page posted / deleted / blocked something.
        let _ = (LuckgramSquare.changed.get() |> take(1)).start(next: { n in
            if n != state.seenChange {
                state.seenChange = n
                load(reset: true)
            }
        })
        guard !pullInstalled, let node = controller?.displayNode as? ItemListControllerNode else {
            return
        }
        pullInstalled = true
        // Pull down past the top to refresh (spec 26 item 2).
        let previous = node.listNode.visibleContentOffsetChanged
        node.listNode.visibleContentOffsetChanged = { offset, transition in
            previous(offset, transition)
            if case let .known(value) = offset {
                if value < -90.0 && state.pullArmed && !state.loading {
                    state.pullArmed = false
                    load(reset: true)
                } else if value >= 0.0 {
                    state.pullArmed = true
                }
            }
        }
    }
    requests.add(ActionDisposable {
        listRequest.dispose()
    })
    let _ = LuckgramSquare.refreshLink().start()
    load(reset: true)
    return controller
}
