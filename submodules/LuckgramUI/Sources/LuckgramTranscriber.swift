import Foundation
import AVFoundation
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext

/// spec 17: free transcription of voice messages and round videos for non-Premium accounts, through
/// the Luckgram AI gateway (`LuckgramAI.transcribe`). Premium accounts keep using Telegram's own
/// transcription and never reach this type.
///
/// The text is stored with `storeLocallyTranscribedAudio`, the same message attribute Telegram uses
/// for its own transcriptions, so the chat shows it again without a new request (and it is removed
/// with the account's data). A failure is kept in memory only and shown in the bubble as
/// "转写失败 · 重试"; tapping the transcribe button again retries.
public enum LuckgramTranscriber {
    /// Messages whose last attempt failed (main queue only, not persisted).
    private static var failed = Set<EngineMessage.Id>()

    /// True when non-Premium transcription should go through Luckgram.
    public static func handles(isPremium: Bool) -> Bool {
        return !isPremium && LuckgramSettings.shared.isEnabled(LuckgramFeatures.freeTranscribe)
    }

    public static func isFailed(_ id: EngineMessage.Id) -> Bool {
        return self.failed.contains(id)
    }

    public static func setFailed(_ id: EngineMessage.Id, _ value: Bool) {
        if value {
            self.failed.insert(id)
        } else {
            self.failed.remove(id)
        }
    }

    public static var failureText: String {
        return LuckgramStrings.pick("转写失败 · 重试", "Transcription failed · Retry")
    }

    /// Downloads the message's audio if needed, transcribes it and stores the text on the message.
    /// Fails with `LuckgramAIError` (`consentDenied` if the user declined the AI consent dialog).
    public static func transcribe(context: AccountContext, message: EngineMessage, present: @escaping (ViewController) -> Void) -> Signal<Never, LuckgramAIError> {
        guard let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
            return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
        }
        let isVideo = file.isInstantVideo
        let mimeType = file.mimeType.hasPrefix("audio/") ? file.mimeType : "audio/ogg"
        let messageId = message.id

        let fetch = context.engine.resources.fetch(
            reference: .media(media: .message(message: MessageReference(message._asMessage()), media: file), resource: file.resource),
            userLocation: .peer(message.id.peerId),
            userContentType: isVideo ? .video : .audio
        )
        let path: Signal<String, LuckgramAIError> = Signal { subscriber in
            let fetchDisposable = fetch.start(error: { _ in
                subscriber.putError(LuckgramAIError(code: LuckgramAIError.networkError))
            })
            let dataDisposable = (context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id))
            |> filter { $0.isComplete }
            |> take(1)).start(next: { data in
                subscriber.putNext(data.path)
                subscriber.putCompletion()
            })
            return ActionDisposable {
                fetchDisposable.dispose()
                dataDisposable.dispose()
            }
        }
        // Offline the download just waits; give up so the bubble can show "failed · retry".
        |> timeout(30.0, queue: Queue.mainQueue(), alternate: .fail(LuckgramAIError(code: LuckgramAIError.networkError)))

        return path
        |> mapToSignal { path -> Signal<(Data, String), LuckgramAIError> in
            return Signal { subscriber in
                Queue.concurrentDefaultQueue().async {
                    if isVideo {
                        extractAudio(videoPath: path, completion: { data in
                            if let data, !data.isEmpty {
                                subscriber.putNext((data, "audio/mp4"))
                                subscriber.putCompletion()
                            } else {
                                subscriber.putError(LuckgramAIError(code: LuckgramAIError.invalidRequest))
                            }
                        })
                    } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
                        subscriber.putNext((data, mimeType))
                        subscriber.putCompletion()
                    } else {
                        subscriber.putError(LuckgramAIError(code: LuckgramAIError.invalidRequest))
                    }
                }
                return EmptyDisposable
            }
        }
        |> mapToSignal { audio, mime -> Signal<LuckgramAI.Transcription, LuckgramAIError> in
            return LuckgramAI.shared.transcribe(context: context, present: present, audio: audio, mimeType: mime)
        }
        |> mapToSignal { result -> Signal<Never, LuckgramAIError> in
            var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let error = result.partialError {
                text += LuckgramStrings.pick("\n\n（后面的部分未转写：", "\n\n(The rest was not transcribed: ") + error.localizedMessage + LuckgramStrings.pick("）", ")")
            }
            return context.engine.messages.storeLocallyTranscribedAudio(messageId: messageId, text: text, isFinal: true, error: nil)
            |> castError(LuckgramAIError.self)
        }
        |> deliverOnMainQueue
    }

    /// Copies a round video's audio track into an M4A file (passthrough, no re-encoding).
    private static func extractAudio(videoPath: String, completion: @escaping (Data?) -> Void) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let input = tempDir.appendingPathComponent("lg_transcribe_\(UInt64.random(in: 0 ... UInt64.max)).mp4")
        let output = tempDir.appendingPathComponent("lg_transcribe_\(UInt64.random(in: 0 ... UInt64.max)).m4a")
        // AVAsset needs a file extension to recognise the container.
        guard (try? FileManager.default.linkItem(atPath: videoPath, toPath: input.path)) != nil || (try? FileManager.default.copyItem(atPath: videoPath, toPath: input.path)) != nil else {
            completion(nil)
            return
        }
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            try? FileManager.default.removeItem(at: input)
            completion(nil)
            return
        }
        session.outputURL = output
        session.outputFileType = .m4a
        session.exportAsynchronously {
            let data = session.status == .completed ? try? Data(contentsOf: output) : nil
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
            completion(data)
        }
    }
}
