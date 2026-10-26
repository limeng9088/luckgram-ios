import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData

/// Luckgram: posts a finished call recording (spec 04 §4–5).
///
/// 1. Sends the Ogg/Opus data as an audio file (not a voice message) to Saved Messages or the
///    chosen chat, named "通话 <name> <date time>.ogg", caption "与 <name> 的通话 · <duration>".
/// 2. If the AI transcript switch is on and the user agreed to AI processing, transcribes and
///    summarises it via the Luckgram AI gateway and replies to the audio message with the summary
///    followed by the full transcript.
/// 3. Removes the local upload copy from the media box once the message is on the server.
final class LuckgramCallRecordingUploader {
    /// Telegram's text limit is 4096; leave room for the header.
    private static let maxTextChunk = 4000
    
    private static var active: [LuckgramCallRecordingUploader] = []
    
    private let context: AccountContext
    private let peer: EnginePeer
    private let data: Data
    private let duration: Double
    private let startDate: Date
    private let correlationId = Int64.random(in: Int64.min ... Int64.max)
    private let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
    
    private var targetPeerId: EnginePeer.Id?
    private var deliveredDisposable: Disposable?
    private var sentMessageId: EngineMessage.Id?
    private var aiDone = false
    private var aiReply: String?
    
    static func upload(context: AccountContext, peer: EnginePeer, data: Data, duration: Double, startDate: Date) {
        let uploader = LuckgramCallRecordingUploader(context: context, peer: peer, data: data, duration: duration, startDate: startDate)
        self.active.append(uploader)
        uploader.start()
    }
    
    private init(context: AccountContext, peer: EnginePeer, data: Data, duration: Double, startDate: Date) {
        self.context = context
        self.peer = peer
        self.data = data
        self.duration = duration
        self.startDate = startDate
    }
    
    private func start() {
        let account = self.context.account
        let wantedTarget = LuckgramCallRecordingSettings.targetPeerId(account: account)
        let targetSignal: Signal<EnginePeer.Id, NoError>
        if let wantedTarget {
            // Fall back to Saved Messages if the chosen chat is gone.
            targetSignal = self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: wantedTarget))
            |> map { peer -> EnginePeer.Id in
                return peer != nil ? wantedTarget : account.peerId
            }
        } else {
            targetSignal = .single(account.peerId)
        }
        let _ = (targetSignal |> deliverOnMainQueue).start(next: { [weak self] targetPeerId in
            self?.send(to: targetPeerId)
        })
        self.startAi()
    }
    
    private func send(to targetPeerId: EnginePeer.Id) {
        self.targetPeerId = targetPeerId
        let account = self.context.account
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        var peerName = self.peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        if peerName.isEmpty {
            peerName = "?"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let title = LuckgramCallRecordingStrings.fileTitle(peerName: peerName, dateTime: formatter.string(from: self.startDate))
        let fileName = LuckgramCallRecordingUploader.sanitize(title) + ".ogg"
        let durationSeconds = max(1, Int(self.duration.rounded()))
        let caption = LuckgramCallRecordingStrings.caption(peerName: peerName, duration: luckgramFormatDuration(durationSeconds))
        
        account.postbox.mediaBox.storeResourceData(self.resource.id, data: self.data, synchronous: true)
        let file = TelegramMediaFile(
            fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)),
            partialReference: nil,
            resource: self.resource,
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "audio/ogg",
            size: Int64(self.data.count),
            attributes: [
                .FileName(fileName: fileName),
                .Audio(isVoice: false, duration: durationSeconds, title: title, performer: peerName, waveform: nil)
            ],
            alternativeRepresentations: []
        )
        
        let correlationId = self.correlationId
        guard let pendingMessageManager = account.pendingMessageManager else {
            return
        }
        // Subscribe before enqueueing so the delivery event cannot be missed.
        self.deliveredDisposable = (pendingMessageManager.deliveredMessageEvents(peerId: targetPeerId)
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self, self.sentMessageId == nil else {
                return
            }
            if let id = pendingMessageManager.synchronouslyLookupCorrelationId(correlationId: correlationId) {
                self.sentMessageId = id
                self.deliveredDisposable?.dispose()
                self.deliveredDisposable = nil
                // The local upload copy is no longer needed (spec 04 §5).
                let resourceId = self.resource.id
                Queue.mainQueue().after(5.0, {
                    let _ = account.postbox.mediaBox.removeCachedResources([resourceId], force: true).start()
                })
                self.maybeFinish()
            }
        })
        
        let _ = enqueueMessages(account: account, peerId: targetPeerId, messages: [
            .message(text: caption, attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: correlationId, bubbleUpEmojiOrStickersets: [])
        ]).start()
    }
    
    private static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        return name.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }
    
    // MARK: AI
    
    private func startAi() {
        guard LuckgramCallRecordingSettings.isAiTranscriptEnabled, let ai = LuckgramCallRecordingAIRegistry.instance, ai.hasConsent else {
            self.aiDone = true
            return
        }
        if self.data.count > LuckgramCallRecordingAIRegistry.maxTranscribeBytes {
            self.finishAi(LuckgramCallRecordingStrings.tooLongForTranscript)
            return
        }
        ai.transcribe(audio: self.data, mimeType: "audio/ogg", completion: { [weak self] text, error in
            guard let self else {
                return
            }
            guard let text, error == nil else {
                self.finishAi(LuckgramCallRecordingStrings.transcriptFailed(error ?? "?"))
                return
            }
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.isEmpty {
                self.finishAi(LuckgramCallRecordingStrings.transcriptHeader + "\n" + LuckgramCallRecordingStrings.transcriptEmpty)
                return
            }
            ai.summarize(transcript: transcript, completion: { [weak self] summary, summaryError in
                guard let self else {
                    return
                }
                var reply = ""
                if summaryError == nil, let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    reply += LuckgramCallRecordingStrings.summaryHeader + "\n" + summary + "\n\n"
                }
                reply += LuckgramCallRecordingStrings.transcriptHeader + "\n" + transcript
                self.finishAi(reply)
            })
        })
    }
    
    private func finishAi(_ reply: String) {
        self.aiReply = reply
        self.aiDone = true
        self.maybeFinish()
    }
    
    private func maybeFinish() {
        guard self.aiDone, let sentMessageId = self.sentMessageId, let targetPeerId = self.targetPeerId else {
            return
        }
        if let aiReply = self.aiReply {
            let messages: [EnqueueMessage] = LuckgramCallRecordingUploader.split(aiReply).map { chunk in
                return .message(text: chunk, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: EngineMessageReplySubject(messageId: sentMessageId, quote: nil, innerSubject: nil), replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
            }
            let _ = enqueueMessages(account: self.context.account, peerId: targetPeerId, messages: messages).start()
        }
        LuckgramCallRecordingUploader.active.removeAll(where: { $0 === self })
    }
    
    static func split(_ text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var end = rest.index(rest.startIndex, offsetBy: maxTextChunk, limitedBy: rest.endIndex) ?? rest.endIndex
            if end < rest.endIndex {
                let window = rest[rest.startIndex ..< end]
                let half = rest.index(rest.startIndex, offsetBy: maxTextChunk / 2)
                if let nl = window.lastIndex(of: "\n"), nl > half {
                    end = nl
                } else if let sp = window.lastIndex(of: " "), sp > half {
                    end = sp
                }
            }
            let part = rest[rest.startIndex ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty {
                result.append(result.isEmpty ? part : LuckgramCallRecordingStrings.transcriptContinued + "\n" + part)
            }
            rest = rest[end...]
        }
        return result
    }
}
