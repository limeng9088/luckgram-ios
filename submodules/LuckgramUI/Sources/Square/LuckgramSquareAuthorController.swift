import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI
import LuckgramDiscover

// Author card (spec 26 item 3): display name, avatar, bio and the author's posts; "Send message"
// when the author chose to show a public username. Report / block from the "⋯" button. Same as
// SquareAuthorActivity on Android.

private final class SquareAuthorArguments {
    let feed: SquareFeedArguments
    let sendMessage: () -> Void

    init(feed: SquareFeedArguments, sendMessage: @escaping () -> Void) {
        self.feed = feed
        self.sendMessage = sendMessage
    }
}

private enum SquareAuthorEntry: ItemListNodeEntry {
    case card(String, String, UIImage?)
    case message(String)
    case header(String)
    case post(LuckgramSquarePostEntry)

    var section: ItemListSectionId {
        switch self {
        case .card, .message:
            return 0
        case .header:
            return 1
        case let .post(e):
            return e.section + 1
        }
    }

    var stableId: Int64 {
        switch self {
        case .card: return -3
        case .message: return -2
        case .header: return -1
        case let .post(e): return e.stableId
        }
    }

    static func == (lhs: SquareAuthorEntry, rhs: SquareAuthorEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.card(a1, a2, a3), .card(b1, b2, b3)): return a1 == b1 && a2 == b2 && a3 === b3
        case let (.message(a), .message(b)): return a == b
        case let (.header(a), .header(b)): return a == b
        case let (.post(a), .post(b)): return a == b
        default: return false
        }
    }

    static func < (lhs: SquareAuthorEntry, rhs: SquareAuthorEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SquareAuthorArguments
        switch self {
        case let .card(name, bio, avatar):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: avatar, title: name, label: bio, labelStyle: .detailText, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .message(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.sendMessage()
            })
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text.uppercased(), sectionId: self.section)
        case let .post(e):
            return e.item(presentationData: presentationData, arguments: arguments.feed)
        }
    }
}

private final class SquareAuthorState {
    var author: SquareLogic.Author
    var posts: [SquareLogic.Post] = []
    var nextCursor: String?
    var loading = false
    var loadedOnce = false
    var failed = false
    let avatars = LuckgramSquareAvatars()

    init(author: SquareLogic.Author) {
        self.author = author
    }
}

public func luckgramSquareAuthorController(context: AccountContext, author: SquareLogic.Author) -> ViewController {
    return luckgramSquareAuthorController(context: context, userId: author.id, initial: author)
}

public func luckgramSquareAuthorController(context: AccountContext, userId: String, initial: SquareLogic.Author? = nil) -> ViewController {
    let tx = LuckgramSquare.texts
    let state = SquareAuthorState(author: initial ?? SquareLogic.Author(id: userId))
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    func refresh() {
        version += 1
        updated.set(version)
    }
    state.avatars.updated = { refresh() }

    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?
    var controllerRef: ViewController?
    let present: (ViewController) -> Void = { presentImpl?($0) }
    let push: (ViewController) -> Void = { pushImpl?($0) }
    let requests = DisposableSet()
    let listRequest = MetaDisposable()
    let isMe = LuckgramSquare.myAuthorId != nil && LuckgramSquare.myAuthorId == userId

    func loadAuthor() {
        requests.add(LuckgramAI.shared.requestJSON(method: "GET", path: SquareLogic.userPath(userId)).start(next: { j in
            let a = SquareLogic.parseAuthor((j["author"] as? [String: Any]) ?? j)
            if !a.id.isEmpty {
                state.author = a
                refresh()
            }
        }, error: { error in
            if initial == nil && (error.httpStatus == 404 || error.code == "not_found") {
                LuckgramSquare.toast(context: context, tx.authorGone, present: present)
                dismissImpl?()
            }
        }))
    }

    func load(reset: Bool) {
        if reset {
            state.posts = []
            state.nextCursor = nil
            state.loadedOnce = false
        }
        state.loading = true
        state.failed = false
        refresh()
        listRequest.set(LuckgramAI.shared.requestJSON(method: "GET", path: SquareLogic.withCursor(SquareLogic.userPostsPath(userId), cursor: state.nextCursor)).start(next: { j in
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

    let feedArguments = SquareFeedArguments(openAuthor: { _ in
        // already on the author's page
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
            dismissImpl?()
        })
    }, loadMore: {
        if !state.loading && state.nextCursor != nil {
            load(reset: false)
        }
    }, retry: {
        load(reset: state.posts.isEmpty)
    })

    let arguments = SquareAuthorArguments(feed: feedArguments, sendMessage: {
        guard let username = state.author.username, !username.isEmpty else {
            LuckgramSquare.toast(context: context, tx.noPublicUsername, present: present)
            return
        }
        LuckgramSquare.openUsername(username, context: context, navigationController: controllerRef?.navigationController as? NavigationController)
    })

    let entries = updated.get() |> map { _ -> [SquareAuthorEntry] in
        var e: [SquareAuthorEntry] = []
        let a = state.author
        var sub = a.bio
        if let u = a.username, !u.isEmpty {
            sub = "@" + u + (a.bio.isEmpty ? "" : " · " + a.bio)
        }
        e.append(.card(a.displayName.isEmpty ? tx.title : a.displayName, sub, state.avatars.image(for: a)))
        if let u = a.username, !u.isEmpty {
            e.append(.message(tx.sendMessage))
        }
        e.append(.header(tx.authorPosts))
        for (i, post) in state.posts.enumerated() {
            for row in LuckgramSquarePostEntry.rows(for: post, index: i, section: Int32(i + 1), avatar: state.avatars.image(for: post.author), full: false) {
                e.append(.post(row))
            }
        }
        let tail = Int32(state.posts.count + 1)
        let tailIndex = state.posts.count
        if state.loading {
            e.append(.post(.footer(tail, tailIndex, tx.loading, 0)))
        } else if state.failed {
            e.append(.post(.action(tail, tailIndex, tx.refresh, 2)))
        } else if state.loadedOnce && state.posts.isEmpty {
            e.append(.post(.footer(tail, tailIndex, tx.empty, 0)))
        } else if state.nextCursor != nil {
            e.append(.post(.action(tail, tailIndex, tx.loadMore, 1)))
        } else if !state.posts.isEmpty {
            e.append(.post(.footer(tail, tailIndex, tx.noMore, 0)))
        }
        return e
    }

    let signal = combineLatest(context.sharedContext.presentationData, entries)
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var rightButton: ItemListNavigationButton?
        if !isMe {
            rightButton = ItemListNavigationButton(content: .text(tx.more), style: .regular, enabled: true, action: {
                present(textAlertController(context: context, title: state.author.displayName, text: "", actions: [
                    TextAlertAction(type: .genericAction, title: tx.reportAuthor, action: {
                        LuckgramSquare.report(context: context, target: "user", id: userId, present: present, push: push)
                    }),
                    TextAlertAction(type: .destructiveAction, title: tx.block, action: {
                        LuckgramSquare.block(context: context, author: state.author, present: present, push: push, done: {
                            dismissImpl?()
                        })
                    }),
                    TextAlertAction(type: .defaultAction, title: tx.cancel, action: {})
                ], actionLayout: .vertical))
            })
        }
        let title = state.author.displayName.isEmpty ? tx.title : state.author.displayName
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controllerRef = controller
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    controller.visibleBottomContentOffsetChanged = { offset in
        if case let .known(value) = offset, value < 300.0, !state.loading, state.nextCursor != nil, state.loadedOnce {
            load(reset: false)
        }
    }
    requests.add(ActionDisposable {
        listRequest.dispose()
    })
    LuckgramSquare.prefetchMe()
    loadAuthor()
    load(reset: true)
    return controller
}
