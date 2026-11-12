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
import PromptUI
import TextFormat
import LuckgramDiscover

// One post with its comments (spec 26 item 5): one level of comments plus one level of replies,
// each ≤ 300 characters. Comment authors delete their own comments; the post author can delete
// any comment under the post. Same rules as SquarePostActivity on Android.

private final class SquarePostArguments {
    let post: SquareFeedArgumentsProxy
    let openComment: (Int) -> Void
    let write: () -> Void
    let cancelReply: () -> Void
    let retry: () -> Void

    init(post: SquareFeedArgumentsProxy, openComment: @escaping (Int) -> Void, write: @escaping () -> Void, cancelReply: @escaping () -> Void, retry: @escaping () -> Void) {
        self.post = post
        self.openComment = openComment
        self.write = write
        self.cancelReply = cancelReply
        self.retry = retry
    }
}

/// The post rows reuse `LuckgramSquarePostEntry`, whose `item(...)` expects the feed arguments;
/// this adapter maps them onto a single post.
final class SquareFeedArgumentsProxy {
    let openAuthor: () -> Void
    let openVideo: () -> Void
    let more: () -> Void

    init(openAuthor: @escaping () -> Void, openVideo: @escaping () -> Void, more: @escaping () -> Void) {
        self.openAuthor = openAuthor
        self.openVideo = openVideo
        self.more = more
    }
}

private enum SquarePostEntry: ItemListNodeEntry {
    case post(LuckgramSquarePostEntry)
    case header(String)
    case comment(Int, String, String, Bool)
    case info(String)
    case write(String)
    case replying(String)
    case retry(String)

    var section: ItemListSectionId {
        switch self {
        case .post:
            return 0
        case .header, .comment, .info, .retry:
            return 1
        case .write, .replying:
            return 2
        }
    }

    var stableId: Int64 {
        switch self {
        case let .post(e): return e.stableId
        case .header: return 1000
        case let .comment(i, _, _, _): return 1001 + Int64(i)
        case .info: return 100_000
        case .retry: return 100_001
        case .replying: return 100_002
        case .write: return 100_003
        }
    }

    static func == (lhs: SquarePostEntry, rhs: SquarePostEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.post(a), .post(b)): return a == b
        case let (.header(a), .header(b)): return a == b
        case let (.comment(a1, a2, a3, a4), .comment(b1, b2, b3, b4)): return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.info(a), .info(b)): return a == b
        case let (.write(a), .write(b)): return a == b
        case let (.replying(a), .replying(b)): return a == b
        case let (.retry(a), .retry(b)): return a == b
        default: return false
        }
    }

    static func < (lhs: SquarePostEntry, rhs: SquarePostEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SquarePostArguments
        switch self {
        case let .post(e):
            let feedArguments = SquareFeedArguments(openAuthor: { _ in arguments.post.openAuthor() }, openPost: { _ in }, openVideo: { _ in arguments.post.openVideo() }, more: { _ in arguments.post.more() }, loadMore: {}, retry: {})
            return e.item(presentationData: presentationData, arguments: feedArguments)
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text.uppercased(), sectionId: self.section)
        case let .comment(index, label, text, _):
            return ItemListTextWithLabelItem(presentationData: presentationData, label: label, text: text, style: .blocks, enabledEntityTypes: [], multiline: true, sectionId: self.section, action: {
                arguments.openComment(index)
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .write(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.write()
            })
        case let .replying(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.cancelReply()
            })
        case let .retry(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.retry()
            })
        }
    }
}

private final class SquarePostState {
    var post: SquareLogic.Post?
    var comments: [SquareLogic.Comment] = []
    var threaded: [SquareLogic.Comment] = []
    var loadingPost = false
    var loadingComments = false
    var failed = false
    var sending = false
    var replyTo: SquareLogic.Comment?
    let avatars = LuckgramSquareAvatars()
}

public func luckgramSquarePostController(context: AccountContext, post: SquareLogic.Post) -> ViewController {
    return luckgramSquarePostController(context: context, postId: post.id, initial: post)
}

public func luckgramSquarePostController(context: AccountContext, postId: String, initial: SquareLogic.Post? = nil) -> ViewController {
    let tx = LuckgramSquare.texts
    let state = SquarePostState()
    state.post = initial
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
    let present: (ViewController) -> Void = { presentImpl?($0) }
    let push: (ViewController) -> Void = { pushImpl?($0) }
    let requests = DisposableSet()

    func rethread() {
        state.threaded = SquareLogic.thread(state.comments)
        state.post?.commentCount = state.comments.count
    }

    func loadPost() {
        state.loadingPost = true
        refresh()
        requests.add(LuckgramAI.shared.requestJSON(method: "GET", path: SquareLogic.postPath(postId)).start(next: { j in
            state.loadingPost = false
            let p = SquareLogic.parsePost(j)
            if !p.id.isEmpty {
                state.post = p
                state.post?.commentCount = max(p.commentCount, state.comments.count)
            }
            refresh()
        }, error: { error in
            state.loadingPost = false
            if error.httpStatus == 404 || error.code == "not_found" {
                LuckgramSquare.toast(context: context, tx.postGone, present: present)
                LuckgramSquare.noteRemoved(postId)
                dismissImpl?()
                return
            }
            if state.post == nil {
                state.failed = true
            }
            refresh()
            LuckgramSquare.showError(error, context: context, present: present, push: push)
        }))
    }

    func loadComments() {
        state.loadingComments = true
        refresh()
        requests.add(LuckgramAI.shared.requestJSON(method: "GET", path: SquareLogic.postPath(postId) + "/comments").start(next: { j in
            state.loadingComments = false
            state.comments = SquareLogic.parseComments(j).items
            rethread()
            refresh()
        }, error: { error in
            state.loadingComments = false
            refresh()
            LuckgramSquare.showError(error, context: context, present: present, push: push)
        }))
    }

    func reload() {
        state.failed = false
        loadPost()
        loadComments()
    }

    func sendComment(_ text: String) {
        guard !state.sending else {
            return
        }
        if !SquareLogic.isValidComment(text) {
            LuckgramSquare.toast(context: context, SquareLogic.length(text.trimmingCharacters(in: .whitespacesAndNewlines)) > SquareLogic.commentMax ? tx.tooLong : tx.needContent, present: present)
            return
        }
        requests.add(LuckgramSquare.requireProfile(context: context, present: present, push: push, then: {
            state.sending = true
            refresh()
            let parentId = state.replyTo.map { SquareLogic.replyParentId(state.comments, $0) }
            requests.add(LuckgramAI.shared.requestJSON(method: "POST", path: SquareLogic.postPath(postId) + "/comments", body: SquareLogic.commentBody(text: text, parentId: parentId)).start(next: { j in
                state.sending = false
                let c = SquareLogic.parseComment(j)
                if !c.id.isEmpty {
                    if !c.author.id.isEmpty {
                        LuckgramSquare.myAuthorId = c.author.id
                    }
                    state.comments.append(c)
                    rethread()
                }
                state.replyTo = nil
                LuckgramSquare.noteUpdated(state.post)
                refresh()
                LuckgramSquare.toast(context: context, tx.commentSent, present: present)
            }, error: { error in
                state.sending = false
                refresh()
                LuckgramSquare.showError(error, context: context, present: present, push: push)
            }))
        }))
    }

    func deleteComment(_ c: SquareLogic.Comment) {
        requests.add(LuckgramAI.shared.requestJSON(method: "DELETE", path: "/v1/square/comments/" + SquareLogic.pathId(c.id)).start(next: { _ in
            // Replies to a deleted comment go with it (they would become orphans / top comments).
            state.comments.removeAll(where: { $0.id == c.id || $0.parentId == c.id })
            if state.replyTo?.id == c.id {
                state.replyTo = nil
            }
            rethread()
            LuckgramSquare.noteUpdated(state.post)
            refresh()
            LuckgramSquare.toast(context: context, tx.deleted, present: present)
        }, error: { error in
            LuckgramSquare.showError(error, context: context, present: present, push: push)
        }))
    }

    func writeComment() {
        let title = state.replyTo.map { tx.replyingTo($0.author.displayName) } ?? tx.comment
        present(promptController(context: context, text: title, value: "", placeholder: tx.commentHint, characterLimit: SquareLogic.commentMax, displayCharacterLimit: true, apply: { text in
            if let text {
                sendComment(text)
            }
        }))
    }

    let postProxy = SquareFeedArgumentsProxy(openAuthor: {
        if let p = state.post {
            push(luckgramSquareAuthorController(context: context, author: p.author))
        }
    }, openVideo: {
        if let video = state.post?.video {
            LuckgramSquareVideoPlayer.present(video, context: context, fallback: nil)
        }
    }, more: {
        guard let p = state.post else {
            return
        }
        LuckgramSquare.showPostMenu(context: context, post: p, present: present, push: push, onLiked: { updatedPost in
            state.post = updatedPost
            refresh()
        }, onComment: {
            writeComment()
        }, onDeleted: {
            dismissImpl?()
        }, onBlocked: {
            dismissImpl?()
        })
    })

    let arguments = SquarePostArguments(post: postProxy, openComment: { index in
        guard index < state.threaded.count else {
            return
        }
        let c = state.threaded[index]
        var actions: [TextAlertAction] = []
        actions.append(TextAlertAction(type: .genericAction, title: tx.reply, action: {
            state.replyTo = c
            refresh()
            writeComment()
        }))
        if SquareLogic.canDeleteComment(c, post: state.post, myId: LuckgramSquare.myAuthorId) {
            actions.append(TextAlertAction(type: .destructiveAction, title: tx.delete, action: {
                present(textAlertController(context: context, title: tx.delete, text: tx.deleteCommentConfirm, actions: [
                    TextAlertAction(type: .genericAction, title: tx.cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: tx.delete, action: {
                        deleteComment(c)
                    })
                ]))
            }))
        }
        if c.author.id != LuckgramSquare.myAuthorId {
            actions.append(TextAlertAction(type: .genericAction, title: tx.reportComment, action: {
                LuckgramSquare.report(context: context, target: "comment", id: c.id, present: present, push: push)
            }))
        }
        actions.append(TextAlertAction(type: .defaultAction, title: tx.cancel, action: {}))
        present(textAlertController(context: context, title: c.author.displayName, text: c.text, actions: actions, actionLayout: .vertical))
    }, write: {
        writeComment()
    }, cancelReply: {
        state.replyTo = nil
        refresh()
    }, retry: {
        reload()
    })

    let entries = updated.get() |> map { _ -> [SquarePostEntry] in
        var e: [SquarePostEntry] = []
        if let p = state.post {
            for row in LuckgramSquarePostEntry.rows(for: p, index: 0, section: 0, avatar: state.avatars.image(for: p.author), full: true) {
                e.append(.post(row))
            }
        } else if state.loadingPost {
            e.append(.post(.footer(0, 0, tx.loading, 0)))
        } else if state.failed {
            e.append(.retry(tx.refresh))
            return e
        }
        e.append(.header(tx.commentsHeader))
        if state.loadingComments && state.comments.isEmpty {
            e.append(.info(tx.commentsLoading))
        } else if state.threaded.isEmpty {
            e.append(.info(tx.noComments))
        } else {
            for (i, c) in state.threaded.enumerated() {
                var label = (c.depth > 0 ? "↳ " : "") + c.author.displayName + "  ·  " + tx.timeAgo(c.createdAt, now: Date())
                if c.status == SquareLogic.statusHidden {
                    label += "  ·  " + tx.hidden
                }
                e.append(.comment(i, label, c.text, c.depth > 0))
            }
        }
        if let r = state.replyTo {
            e.append(.replying(tx.replyingTo(r.author.displayName) + " · " + tx.cancelReply))
        }
        e.append(.write(state.sending ? tx.publishing : tx.commentHint))
        return e
    }

    let signal = combineLatest(context.sharedContext.presentationData, entries)
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tx.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
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
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    // specs#115: time on this page, reported as a view with tab=detail when it goes away
    var shownAt: Int64 = 0
    controller.didAppear = { _ in
        shownAt = SquareEvents.nowMs()
    }
    controller.didDisappear = { _ in
        if shownAt > 0 {
            let now = SquareEvents.nowMs()
            let dwell = min(SquareEvents.maxDwellMs, now - shownAt)
            shownAt = 0
            if dwell > 0 {
                LuckgramSquareEvents.add([SquareEvents.Event(type: SquareEvents.view, postId: postId, tab: SquareEvents.tabDetail, dwellMs: dwell, timeMs: now)])
            }
            LuckgramSquareEvents.flush(force: true)
        }
    }
    LuckgramSquare.prefetchMe()
    reload()
    return controller
}
