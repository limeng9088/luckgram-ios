import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// Silent S6 device ↔ account link, shared by People Nearby (25) and Square (26). Nothing about
/// "linking an account" is shown: `POST /v1/link/start` → `/start <nonce>` is sent to the bot from
/// the current account → poll `GET /v1/link?nonce=` until the server has it → the bot chat is
/// cleared locally. Callers show their own short "connecting" / failure notice. Extracted from
/// w-1136's Square code so both features keep one copy (same as `SilentLink` on Android).
///
/// specs#209: each Telegram account has its own device token (`LuckgramAccountTokens`), so the
/// state here is kept per Telegram user too (`EnginePeer.Id.toInt64()`); switching accounts never
/// reuses another account's link. Main queue.
public enum LuckgramSilentLink {
    /// How long the silent link may take before giving up (nonce TTL is 10 minutes; be quicker).
    private static let timeout: TimeInterval = 90

    private static var linkedByUser: [Int64: Bool] = [:]
    private static var linking: Set<Int64> = []
    private static var waiting: [Int64: [(Bool) -> Void]] = [:]
    /// Why the last silent link of a user failed, when the user can act on it (limit_reached).
    private static var failures: [Int64: String] = [:]

    private static func currentUser() -> Int64 {
        return LuckgramAI.shared.currentUser() ?? 0
    }

    /// Last known state of the selected account, nil when not checked yet.
    public static var cached: Bool? {
        return linkedByUser[currentUser()]
    }

    public static func cached(context: AccountContext) -> Bool? {
        return linkedByUser[context.account.peerId.toInt64()]
    }

    /// Forget every account's cached state (logout, delete my data).
    public static func clearCache() {
        linkedByUser = [:]
        failures = [:]
    }

    /// Forget one account's cached state (unlink, a `not_linked` answer).
    public static func clearCache(context: AccountContext) {
        let user = context.account.peerId.toInt64()
        linkedByUser[user] = nil
        failures[user] = nil
    }

    /// The text to show when the last silent link of `context`'s account failed for a reason the
    /// user can act on (the Telegram account already has the most devices), else nil.
    public static func failureMessage(context: AccountContext) -> String? {
        return failures[context.account.peerId.toInt64()]
    }

    /// `GET /v1/link` as `context`'s account (nil = the selected one); delivers the server's
    /// answer, or nil when it couldn't be asked (offline, server error) so callers never mistake
    /// a network error for "unlinked". Main queue.
    public static func refresh(context: AccountContext? = nil) -> Signal<Bool?, NoError> {
        let user = context?.account.peerId.toInt64() ?? currentUser()
        return LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/link", user: user)
        |> map { j -> Bool? in
            let value = (j["linked"] as? Bool) ?? ((j["linked"] as? NSNumber)?.boolValue ?? false)
            linkedByUser[user] = value
            return value
        }
        |> `catch` { _ -> Signal<Bool?, NoError> in
            return .single(nil)
        }
        |> deliverOnMainQueue
    }

    /// Calls `completion` (main queue) once this device is linked to `context`'s Telegram user,
    /// linking it in the background first if needed. Concurrent calls share one attempt.
    public static func ensure(context: AccountContext, completion: @escaping (Bool) -> Void) {
        let user = context.account.peerId.toInt64()
        if linkedByUser[user] == true {
            completion(true)
            return
        }
        waiting[user, default: []].append(completion)
        if linking.contains(user) {
            return
        }
        linking.insert(user)
        failures[user] = nil
        let _ = refresh(context: context).start(next: { ok in
            if ok == true {
                finish(user, true)
            } else {
                start(context: context, user: user)
            }
        })
    }

    private static func start(context: AccountContext, user: Int64) {
        let _ = LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/link/start", user: user).start(next: { j in
            let st = LuckgramAccountLogic.parseStart(j)
            guard let bot = LuckgramAccountLogic.botUsername(st.url), !st.nonce.isEmpty else {
                finish(user, false)
                return
            }
            let deadline = min(st.expiresAt ?? Date.distantFuture, Date().addingTimeInterval(timeout))
            var resolved = false
            let _ = (context.engine.peers.resolvePeerByName(name: bot, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                if case let .result(peer) = result {
                    return .single(peer)
                }
                return .complete()
            }
            |> take(1)
            |> deliverOnMainQueue).start(next: { peer in
                resolved = true
                guard let peer else {
                    finish(user, false)
                    return
                }
                let _ = enqueueMessages(account: context.account, peerId: peer.id, messages: [.message(text: LuckgramAccountLogic.startCommand(st.nonce), attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()
                poll(context: context, user: user, nonce: st.nonce, botPeerId: peer.id, deadline: deadline)
            }, completed: {
                if !resolved {
                    Queue.mainQueue().async {
                        finish(user, false)
                    }
                }
            })
        }, error: { error in
            if error.code == "already_linked" {
                linkedByUser[user] = true
                finish(user, true)
            } else {
                finish(user, false)
            }
        })
    }

    private static func poll(context: AccountContext, user: Int64, nonce: String, botPeerId: EnginePeer.Id, deadline: Date) {
        guard LuckgramAccountLogic.shouldPoll(request: nil, now: Date(), expiresAt: deadline) else {
            finish(user, false)
            return
        }
        let again: () -> Void = {
            let _ = (Signal<Void, NoError>.single(Void()) |> delay(LuckgramAccountLogic.pollInterval, queue: .mainQueue())).start(next: {
                poll(context: context, user: user, nonce: nonce, botPeerId: botPeerId, deadline: deadline)
            })
        }
        let _ = LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/link?nonce=\(nonce)", user: user).start(next: { j in
            let s = LuckgramAccountLogic.parseLink(j)
            if s.linked || s.request == "linked" {
                linkedByUser[user] = true
                // The bot conversation is cleaned up so the user isn't bothered by it.
                clearBotChat(context: context, botPeerId: botPeerId)
                finish(user, true)
            } else if LuckgramAccountLogic.shouldPoll(request: s.request, now: Date(), expiresAt: deadline) {
                again()
            } else {
                if s.request == "limit_reached" {
                    // specs#209: tell the user instead of failing silently.
                    failures[user] = LuckgramAccountLogic.Texts(zh: LuckgramStrings.isChinese).linkResult(s.request, max: s.maxDevices)
                    clearBotChat(context: context, botPeerId: botPeerId)
                }
                finish(user, false)
            }
        }, error: { _ in
            again() // offline for a moment: keep trying until the deadline
        })
    }

    /// Removes the bot conversation from the chat list so no trace of the link is left (spec 26
    /// item 2): the whole dialog is deleted locally, not just its history, which would leave a
    /// "History was cleared" row at the top (acceptance P1). Done now and again a little later:
    /// the server records the link before the bot sends its reply, so the reply may land after
    /// the first delete (review P2).
    private static func clearBotChat(context: AccountContext, botPeerId: EnginePeer.Id) {
        let clear: () -> Void = {
            let _ = context.engine.peers.removePeerChat(peerId: botPeerId, reportChatSpam: false, deleteGloballyIfPossible: false).start()
        }
        clear()
        for d in LuckgramAccountLogic.botCleanupDelays {
            let _ = (Signal<Void, NoError>.single(Void()) |> delay(d, queue: .mainQueue())).start(next: {
                clear()
            })
        }
        // The reply can come later still (review P2): watch the bot chat for a while and delete
        // whatever the bot sends there right away.
        let watch = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.TopMessage(id: botPeerId))
        |> deliverOnMainQueue).start(next: { message in
            if let message, message.flags.contains(.Incoming) {
                clear()
            }
        })
        let _ = (Signal<Void, NoError>.single(Void()) |> delay(LuckgramAccountLogic.botWatchSeconds, queue: .mainQueue())).start(next: {
            watch.dispose()
        })
    }

    private static func finish(_ user: Int64, _ ok: Bool) {
        linking.remove(user)
        let list = waiting[user] ?? []
        waiting[user] = nil
        for w in list {
            w(ok)
        }
    }
}
