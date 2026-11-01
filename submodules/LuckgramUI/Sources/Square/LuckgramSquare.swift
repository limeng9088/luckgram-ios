import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AlertUI
import PresentationDataUtils
import UndoUI
import PromptUI
import LuckgramDiscover

/// Shared pieces of the Square pages (spec 26): link / profile checks before writes, error
/// messages, report and block, the like toggle and a small image cache. Same rules as
/// `SquareUi` on Android. Network calls go through `LuckgramAI`; nothing is sent while the
/// `square` switch is off because the entry is hidden then.
public enum LuckgramSquare {
    public static var isFeatureEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(SquareLogic.featureKey)
    }

    public static var texts: SquareLogic.Texts {
        return SquareLogic.Texts(zh: LuckgramStrings.isChinese)
    }

    public static var maxPostsPerDay: Int {
        return LuckgramSettings.shared.remoteInt("square.max_posts_per_day", default: SquareLogic.defaultMaxPostsPerDay)
    }

    // MARK: - link / profile state

    static var linked: Bool?
    static var profile: [String: Any]?
    /// Author id of this device's user in Square (from the profile response), if known.
    public static var myAuthorId: String?
    /// Bumped whenever a page changed something the feed should reload (post, delete, block).
    public static let changed = ValuePromise<Int>(0, ignoreRepeated: false)
    private static var changeCounter = 0

    public static func markChanged() {
        changeCounter += 1
        changed.set(changeCounter)
    }

    /// Forget cached state (unlink, logout, "delete my Square data").
    public static func clearCache() {
        linked = nil
        profile = nil
        myAuthorId = nil
        imageCache.removeAll()
    }

    static func refreshLink() -> Signal<Bool, NoError> {
        return LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/link")
        |> map { j -> Bool in
            let value = (j["linked"] as? Bool) ?? ((j["linked"] as? NSNumber)?.boolValue ?? false)
            linked = value
            if !value {
                profile = nil
                myAuthorId = nil
            }
            return value
        }
        |> `catch` { _ -> Signal<Bool, NoError> in
            return .single(linked ?? false)
        }
    }

    /// Runs `then` if this device is linked (S6); otherwise shows the link prompt.
    static func requireLink(context: AccountContext, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void, then: @escaping () -> Void) -> Disposable {
        if linked == true {
            then()
            return EmptyDisposable
        }
        return refreshLink().start(next: { ok in
            if ok {
                then()
            } else {
                showLinkPrompt(context: context, present: present, push: push)
            }
        })
    }

    static func showLinkPrompt(context: AccountContext, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
        let tx = texts
        present(textAlertController(context: context, title: tx.needLinkTitle, text: tx.needLinkText, actions: [
            TextAlertAction(type: .genericAction, title: tx.cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: tx.goLink, action: {
                push(luckgramAccountController(context: context))
            })
        ]))
    }

    private static func setProfile(_ p: [String: Any]) {
        profile = p
        if let id = p["id"] as? String, !id.isEmpty {
            myAuthorId = id
        }
    }

    /// Linked and has a Square profile: then `then`; otherwise asks for whatever is missing.
    static func requireProfile(context: AccountContext, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void, then: @escaping () -> Void) -> Disposable {
        let disposable = MetaDisposable()
        disposable.set(requireLink(context: context, present: present, push: push, then: {
            if profile != nil {
                then()
                return
            }
            disposable.set(LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/square/profile").start(next: { j in
                if (j["display_name"] as? String ?? "").isEmpty {
                    editProfile(context: context, present: present, then: then)
                } else {
                    setProfile(j)
                    then()
                }
            }, error: { error in
                if error.code == "not_found" || error.code == "profile_required" || error.httpStatus == 404 {
                    editProfile(context: context, present: present, then: then)
                } else {
                    showError(error, context: context, present: present, push: push)
                }
            }))
        }))
        return disposable
    }

    /// Edit (or first fill in) the Square profile: name, then bio, then (if the account has one)
    /// whether to show the public username. `then` runs after a successful save.
    static func editProfile(context: AccountContext, present: @escaping (ViewController) -> Void, then: (() -> Void)?) {
        let tx = texts
        let current = profile
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> deliverOnMainQueue).start(next: { peer in
            let myUsername = peer?.addressName ?? ""
            let defaultName = current?["display_name"] as? String ?? (peer?.displayTitle(strings: context.sharedContext.currentPresentationData.with { $0 }.strings, displayOrder: .firstLast) ?? "")
            present(promptController(context: context, text: current == nil ? tx.profileTitle + "\n" + tx.profileNeeded : tx.editProfile, subtitle: tx.displayName, value: defaultName, placeholder: tx.displayName, characterLimit: 64, apply: { name in
                guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    return
                }
                present(promptController(context: context, text: tx.bio, value: current?["bio"] as? String ?? "", placeholder: tx.bio, characterLimit: SquareLogic.profileBioMax, apply: { bio in
                    let bioText = (bio ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let save: (String) -> Void = { username in
                        let body: [String: Any] = ["display_name": name, "bio": bioText, "username": username]
                        let _ = LuckgramAI.shared.requestJSON(method: "PUT", path: "/v1/square/profile", body: body).start(next: { j in
                            setProfile((j["display_name"] as? String ?? "").isEmpty ? body : j)
                            toast(context: context, tx.saved, present: present)
                            then?()
                        }, error: { error in
                            showError(error, context: context, present: present, push: { _ in })
                        })
                    }
                    if myUsername.isEmpty {
                        save("")
                    } else {
                        present(textAlertController(context: context, title: tx.publicUsername, text: tx.useMyUsername(myUsername), actions: [
                            TextAlertAction(type: .genericAction, title: LuckgramStrings.pick("不显示", "Don't show"), action: { save("") }),
                            TextAlertAction(type: .defaultAction, title: LuckgramStrings.pick("显示", "Show"), action: { save(myUsername) })
                        ]))
                    }
                }))
            }))
        })
    }

    // MARK: - errors

    static func errorText(_ error: LuckgramAIError) -> String {
        let tx = texts
        if error.code == LuckgramAIError.rateLimited {
            return tx.waitSeconds(error.retryAfterSeconds)
        }
        if error.code == "banned" {
            return tx.banned
        }
        return error.localizedMessage
    }

    static func showError(_ error: LuckgramAIError, context: AccountContext, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
        if error.code == LuckgramAIError.cancelled {
            return
        }
        if error.code == "not_linked" {
            linked = false
            showLinkPrompt(context: context, present: present, push: push)
            return
        }
        if error.code == "profile_required" {
            profile = nil
            editProfile(context: context, present: present, then: nil)
            return
        }
        toast(context: context, errorText(error), present: present)
    }

    static func toast(context: AccountContext, _ text: String, present: @escaping (ViewController) -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }

    // MARK: - report / block / like

    /// `target`: post, comment or user.
    static func report(context: AccountContext, target: String, id: String, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
        let tx = texts
        let _ = requireLink(context: context, present: present, push: push, then: {
            var actions: [TextAlertAction] = SquareLogic.reportReasons.map { reason in
                TextAlertAction(type: .genericAction, title: tx.reportReason(reason), action: {
                    let _ = LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/square/report", body: SquareLogic.reportBody(target: target, id: id, reason: reason)).start(next: { _ in
                        toast(context: context, tx.reported, present: present)
                    }, error: { error in
                        showError(error, context: context, present: present, push: push)
                    })
                })
            }
            actions.append(TextAlertAction(type: .defaultAction, title: tx.cancel, action: {}))
            present(textAlertController(context: context, title: tx.reportTitle, text: "", actions: actions, actionLayout: .vertical))
        })
    }

    /// Blocks the author after a confirmation, through the block list shared with People Nearby.
    static func block(context: AccountContext, author: SquareLogic.Author, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void, done: @escaping () -> Void) {
        let tx = texts
        let _ = requireLink(context: context, present: present, push: push, then: {
            present(textAlertController(context: context, title: tx.block, text: tx.blockConfirm(author.displayName), actions: [
                TextAlertAction(type: .genericAction, title: tx.cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: tx.block, action: {
                    let _ = LuckgramBlocks.block(userId: author.id, displayName: author.displayName).start(next: { _ in
                        toast(context: context, tx.blocked, present: present)
                        markChanged()
                        done()
                    }, error: { error in
                        showError(error, context: context, present: present, push: push)
                    })
                })
            ]))
        })
    }

    /// Toggles the like; `changed` gets the post with the server counts.
    static func toggleLike(context: AccountContext, post: SquareLogic.Post, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void, changed: @escaping (SquareLogic.Post) -> Void) {
        let _ = requireLink(context: context, present: present, push: push, then: {
            let like = !post.liked
            let _ = LuckgramAI.shared.requestJSON(method: like ? "POST" : "DELETE", path: SquareLogic.postPath(post.id) + "/like").start(next: { j in
                var p = post
                p.liked = (j["liked"] as? Bool) ?? like
                p.likeCount = max(0, (j["like_count"] as? NSNumber)?.intValue ?? (post.likeCount + (like ? 1 : -1)))
                changed(p)
            }, error: { error in
                showError(error, context: context, present: present, push: push)
            })
        })
    }

    static func deletePost(context: AccountContext, post: SquareLogic.Post, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void, done: @escaping () -> Void) {
        let tx = texts
        present(textAlertController(context: context, title: tx.delete, text: tx.deletePostConfirm, actions: [
            TextAlertAction(type: .genericAction, title: tx.cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: tx.delete, action: {
                let _ = LuckgramAI.shared.requestJSON(method: "DELETE", path: SquareLogic.postPath(post.id)).start(next: { _ in
                    toast(context: context, tx.deleted, present: present)
                    markChanged()
                    done()
                }, error: { error in
                    showError(error, context: context, present: present, push: push)
                })
            })
        ]))
    }

    /// Post "⋯" menu: like, comment, delete (own) / report / block author.
    static func showPostMenu(context: AccountContext, post: SquareLogic.Post, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void, onLiked: @escaping (SquareLogic.Post) -> Void, onComment: @escaping () -> Void, onDeleted: @escaping () -> Void, onBlocked: @escaping () -> Void) {
        let tx = texts
        var actions: [TextAlertAction] = []
        actions.append(TextAlertAction(type: .genericAction, title: post.liked ? tx.unlike : tx.like, action: {
            toggleLike(context: context, post: post, present: present, push: push, changed: onLiked)
        }))
        actions.append(TextAlertAction(type: .genericAction, title: tx.comment, action: onComment))
        if SquareLogic.canDeletePost(post, myId: myAuthorId) {
            actions.append(TextAlertAction(type: .destructiveAction, title: tx.delete, action: {
                deletePost(context: context, post: post, present: present, push: push, done: onDeleted)
            }))
        } else {
            actions.append(TextAlertAction(type: .genericAction, title: tx.reportPost, action: {
                report(context: context, target: "post", id: post.id, present: present, push: push)
            }))
            actions.append(TextAlertAction(type: .genericAction, title: tx.reportAuthor, action: {
                report(context: context, target: "user", id: post.author.id, present: present, push: push)
            }))
            actions.append(TextAlertAction(type: .destructiveAction, title: tx.block, action: {
                block(context: context, author: post.author, present: present, push: push, done: onBlocked)
            }))
        }
        actions.append(TextAlertAction(type: .defaultAction, title: tx.cancel, action: {}))
        present(textAlertController(context: context, title: post.author.displayName, text: "", actions: actions, actionLayout: .vertical))
    }

    // MARK: - images

    private static var imageCache: [String: UIImage] = [:]
    private static var imageLoads: [String: Promise<UIImage?>] = [:]

    /// Cached image for an https URL; loads it once (through the API client so the in-app mock
    /// works too) and delivers on the main queue.
    static func image(url: String) -> Signal<UIImage?, NoError> {
        if let cached = imageCache[url] {
            return .single(cached)
        }
        if let loading = imageLoads[url] {
            return loading.get()
        }
        let promise = Promise<UIImage?>()
        imageLoads[url] = promise
        promise.set(LuckgramAI.shared.fetchData(url: url)
        |> map { data -> UIImage? in
            return UIImage(data: data)
        }
        |> `catch` { _ -> Signal<UIImage?, NoError> in
            return .single(nil)
        }
        |> deliverOnMainQueue
        |> beforeNext { image in
            if let image {
                imageCache[url] = image
            }
            imageLoads.removeValue(forKey: url)
        })
        return promise.get()
    }

    /// Round avatar: the author's picture or a coloured circle with the first letter.
    static func avatar(author: SquareLogic.Author, image: UIImage?, size: CGFloat = 36.0) -> UIImage? {
        return generateImage(CGSize(width: size, height: size), contextGenerator: { contextSize, c in
            c.clear(CGRect(origin: .zero, size: contextSize))
            let rect = CGRect(origin: .zero, size: contextSize)
            c.addEllipse(in: rect)
            c.clip()
            if let cg = image?.cgImage {
                c.translateBy(x: 0, y: contextSize.height)
                c.scaleBy(x: 1, y: -1)
                c.draw(cg, in: rect)
                return
            }
            let colors: [UIColor] = [UIColor(rgb: 0xE56555), UIColor(rgb: 0xF28C48), UIColor(rgb: 0x8E85EE), UIColor(rgb: 0x76C84D), UIColor(rgb: 0x5FBED5), UIColor(rgb: 0x549CDD), UIColor(rgb: 0xF2749A)]
            var hash = 0
            for u in author.id.unicodeScalars {
                hash = (hash &* 31 &+ Int(u.value)) & 0x7fffffff
            }
            c.setFillColor(colors[hash % colors.count].cgColor)
            c.fill(rect)
            let letter = String(author.displayName.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            if !letter.isEmpty {
                let font = Font.semibold(size * 0.42)
                let attributed = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: UIColor.white])
                let textSize = attributed.size()
                UIGraphicsPushContext(c)
                attributed.draw(at: CGPoint(x: (contextSize.width - textSize.width) / 2.0, y: (contextSize.height - textSize.height) / 2.0))
                UIGraphicsPopContext()
            }
        })
    }

    static func timeLine(_ post: SquareLogic.Post) -> String {
        let tx = texts
        var s = tx.timeAgo(post.createdAt, now: Date())
        if post.status == SquareLogic.statusPending {
            s += (s.isEmpty ? "" : " · ") + tx.pending
        }
        return s
    }

    static func openUsername(_ username: String, context: AccountContext, navigationController: NavigationController?) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: "https://t.me/\(username)", forceExternal: false, presentationData: presentationData, navigationController: navigationController, dismissInput: {})
    }
}
