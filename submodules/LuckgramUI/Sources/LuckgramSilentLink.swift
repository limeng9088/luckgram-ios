import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// Silent S6 device ↔ account link, shared by People Nearby (25) and Square (26). Nothing about
/// "linking an account" is shown: `POST /v1/link/start` → `/start <nonce>` is sent to the bot from
/// the current account → poll `GET /v1/link?nonce=` until the server has it → the bot chat is
/// cleared locally. Callers show their own short "connecting" / failure notice. Extracted from
/// w-1136's Square code so both features keep one copy (same as `SilentLink` on Android).
public enum LuckgramSilentLink {
    /// How long the silent link may take before giving up (nonce TTL is 10 minutes; be quicker).
    private static let timeout: TimeInterval = 90

    /// Last known state, nil when not checked yet.
    public private(set) static var cached: Bool?
    private static var linking = false
    private static var waiting: [(Bool) -> Void] = []

    /// Forget the cached state (unlink, logout, a `not_linked` answer).
    public static func clearCache() {
        cached = nil
    }

    /// `GET /v1/link`; delivers the server's answer, or nil when it couldn't be asked (offline,
    /// server error) so callers never mistake a network error for "unlinked". Main queue.
    public static func refresh() -> Signal<Bool?, NoError> {
        return LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/link")
        |> map { j -> Bool? in
            let value = (j["linked"] as? Bool) ?? ((j["linked"] as? NSNumber)?.boolValue ?? false)
            cached = value
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
        if cached == true {
            completion(true)
            return
        }
        waiting.append(completion)
        if linking {
            return
        }
        linking = true
        let _ = refresh().start(next: { ok in
            if ok == true {
                finish(true)
            } else {
                start(context: context)
            }
        })
    }

    private static func start(context: AccountContext) {
        let _ = LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/link/start").start(next: { j in
            let st = LuckgramAccountLogic.parseStart(j)
            guard let bot = LuckgramAccountLogic.botUsername(st.url), !st.nonce.isEmpty else {
                finish(false)
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
                    finish(false)
                    return
                }
                let _ = enqueueMessages(account: context.account, peerId: peer.id, messages: [.message(text: LuckgramAccountLogic.startCommand(st.nonce), attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()
                poll(context: context, nonce: st.nonce, botPeerId: peer.id, deadline: deadline)
            }, completed: {
                if !resolved {
                    Queue.mainQueue().async {
                        finish(false)
                    }
                }
            })
        }, error: { error in
            if error.code == "already_linked" {
                cached = true
                finish(true)
            } else {
                finish(false)
            }
        })
    }

    private static func poll(context: AccountContext, nonce: String, botPeerId: EnginePeer.Id, deadline: Date) {
        guard LuckgramAccountLogic.shouldPoll(request: nil, now: Date(), expiresAt: deadline) else {
            finish(false)
            return
        }
        let again: () -> Void = {
            let _ = (Signal<Void, NoError>.single(Void()) |> delay(LuckgramAccountLogic.pollInterval, queue: .mainQueue())).start(next: {
                poll(context: context, nonce: nonce, botPeerId: botPeerId, deadline: deadline)
            })
        }
        let _ = LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/link?nonce=\(nonce)").start(next: { j in
            let s = LuckgramAccountLogic.parseLink(j)
            if s.linked || s.request == "linked" {
                cached = true
                // The bot conversation is cleaned up so the user isn't bothered by it.
                clearBotChat(context: context, botPeerId: botPeerId)
                finish(true)
            } else if LuckgramAccountLogic.shouldPoll(request: s.request, now: Date(), expiresAt: deadline) {
                again()
            } else {
                finish(false)
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

    private static func finish(_ ok: Bool) {
        linking = false
        let list = waiting
        waiting = []
        for w in list {
            w(ok)
        }
    }
}
