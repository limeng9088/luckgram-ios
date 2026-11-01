import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

/// specs#72: `searchMessages` turns Telegram errors into an empty result, so an AI summary that
/// found nothing can't tell "no messages" from "not allowed". This asks Telegram for one message
/// the same way (history, or replies/topic when `threadId` is set) and returns its error, if any.
/// Emits nil when the request succeeds, the error code and text when Telegram refuses it, and
/// nothing (the caller times out) while there is no connection.
public func luckgramProbeHistoryError(account: Account, peerId: PeerId, threadId: Int64?) -> Signal<(code: Int, text: String)?, NoError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(peerId).flatMap(apiInputPeer)
    }
    |> mapToSignal { inputPeer -> Signal<(code: Int, text: String)?, NoError> in
        guard let inputPeer else {
            return .single((code: 400, text: "PEER_ID_INVALID"))
        }
        let request: Signal<Api.messages.Messages, MTRpcError>
        if let threadId {
            request = account.network.request(Api.functions.messages.getReplies(peer: inputPeer, msgId: Int32(clamping: threadId), offsetId: 0, offsetDate: 0, addOffset: 0, limit: 1, maxId: 0, minId: 0, hash: 0))
        } else {
            request = account.network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 1, maxId: 0, minId: 0, hash: 0))
        }
        return request
        |> map { _ -> (code: Int, text: String)? in
            return nil
        }
        |> `catch` { error -> Signal<(code: Int, text: String)?, NoError> in
            return .single((code: Int(error.errorCode), text: error.errorDescription ?? ""))
        }
    }
}
