import Foundation
import TelegramCore
import AccountContext
import LuckgramUI
import Display
import SwiftSignalKit

/// Luckgram: call recording settings.
///
/// Switches are per device and shared by all accounts (spec 00 §5), read and written through
/// 00's `LuckgramSettings` with the same keys as Android (`call_recording`, …).
///
/// The save-to chat is per account (a peer id only means something inside one account), stored
/// in a small file in the account's own directory, which Telegram removes with the account on
/// logout — nothing is left behind.
public enum LuckgramCallRecordingSettings {
    /// Main switch, default off; turning it on goes through the legal reminder (spec 04 §1).
    public static let enabledKey = "call_recording"
    /// Start recording automatically when a one-on-one call connects. Default off.
    public static let autoRecordKey = "call_recording_auto"
    /// Post a transcript + summary reply via the AI gateway. Default on.
    public static let aiTranscriptKey = "call_recording_ai_transcript"
    
    /// Set when the legal reminder was acknowledged for the current "on" period; cleared on
    /// switch-off so every enable shows it again (spec 04 §1, #58).
    public static let legalAckKey = "call_recording_legal_ack"
    
    /// Local switch AND remote config (`features.call_recording`), via 00's LuckgramSettings
    /// (limeng9088/luckgram-specs#43, #54), AND the legal reminder acknowledged — however the
    /// switch was flipped. Default off (registry).
    public static var isEnabled: Bool {
        get { LuckgramSettings.shared.isEnabled(enabledKey) && isLegalAcknowledged }
        set {
            if newValue {
                // Acknowledge first, so the guard sees an acknowledged switch-on.
                LuckgramSettings.shared.setBool(legalAckKey, true)
                LuckgramSettings.shared.setEnabled(enabledKey, true)
            } else {
                LuckgramSettings.shared.setEnabled(enabledKey, false)
                LuckgramSettings.shared.setBool(legalAckKey, false)
            }
        }
    }
    
    static var isLegalAcknowledged: Bool {
        return LuckgramSettings.shared.bool(legalAckKey, default: false)
    }
    
    /// Raw switch value as written by the Luckgram features page.
    static var isSwitchOn: Bool {
        return LuckgramSettings.shared.bool(enabledKey, default: false)
    }
    
    public static var isAutoRecord: Bool {
        get { LuckgramSettings.shared.bool(autoRecordKey, default: false) }
        set { LuckgramSettings.shared.setBool(autoRecordKey, newValue) }
    }
    
    public static var isAiTranscriptEnabled: Bool {
        get { LuckgramSettings.shared.bool(aiTranscriptKey, default: true) }
        set { LuckgramSettings.shared.setBool(aiTranscriptKey, newValue) }
    }
    
    // MARK: Per-account target chat
    
    private static func targetFilePath(account: Account) -> String {
        return account.basePath + "/luckgram-call-recording-target"
    }
    
    /// nil = Saved Messages.
    public static func targetPeerId(account: Account) -> EnginePeer.Id? {
        guard let data = FileManager.default.contents(atPath: targetFilePath(account: account)),
              let string = String(data: data, encoding: .utf8),
              let value = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let peerId = EnginePeer.Id(value)
        if peerId == account.peerId {
            return nil
        }
        return peerId
    }
    
    public static func setTargetPeerId(account: Account, peerId: EnginePeer.Id?) {
        let path = targetFilePath(account: account)
        if let peerId, peerId != account.peerId {
            try? "\(peerId.toInt64())".data(using: .utf8)?.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// Luckgram: the AI calls call recording needs (spec 04 §4: /v1/transcribe, then /v1/chat
/// task=summary). All AI traffic goes through the shared LuckgramAI client of feature 00, which
/// registers an implementation in `LuckgramCallRecordingAIRegistry`; until it does, recordings
/// are saved as audio only.
public protocol LuckgramCallRecordingAI: AnyObject {
    /// The user already agreed to the AI consent dialog (spec 00 §18).
    var hasConsent: Bool { get }
    /// Shows the shared consent dialog if needed; `completion(true)` when agreed. Main thread.
    func requestConsent(context: AccountContext, completion: @escaping (Bool) -> Void)
    /// POST /v1/transcribe. The size limit is the client's business: it splits the audio by
    /// `ai.transcribe_max_mb` from /v1/config (limeng9088/luckgram-specs#53). Completion on the
    /// main thread with (text, error message); both set = partial transcript (a later segment
    /// failed, e.g. daily quota) whose finished part must be kept.
    func transcribe(audio: Data, mimeType: String, completion: @escaping (String?, String?) -> Void)
    /// `ai.max_input_chars` from /v1/config: the longest text `summarize` accepts.
    var maxSummaryInputChars: Int { get }
    /// POST /v1/chat with task=summary. Completion on the main thread with 3–6 bullet points.
    func summarize(transcript: String, completion: @escaping (String?, String?) -> Void)
}

public enum LuckgramCallRecordingAIRegistry {
    public static var instance: LuckgramCallRecordingAI? = LuckgramCallRecordingLuckgramAI()
}

/// `LuckgramCallRecordingAI` on top of 00's `LuckgramAI`.
final class LuckgramCallRecordingLuckgramAI: LuckgramCallRecordingAI {
    /// Same default as the server's ai.max_input_chars.
    private static let defaultMaxInputChars = 60000
    
    var hasConsent: Bool {
        return LuckgramAI.shared.hasConsent
    }
    
    func requestConsent(context: AccountContext, completion: @escaping (Bool) -> Void) {
        let present: (ViewController) -> Void = { controller in
            context.sharedContext.mainWindow?.present(controller, on: .root, blockInteraction: false, completion: {})
        }
        let _ = (LuckgramAI.shared.requestConsent(context: context, present: present)
        |> deliverOnMainQueue).start(next: { agreed in
            completion(agreed)
        })
    }
    
    func transcribe(audio: Data, mimeType: String, completion: @escaping (String?, String?) -> Void) {
        // Consent was given before the call (settings); no alert can be shown after hang-up, and
        // LuckgramAI does not ask again once agreed (context/present nil = deny if not agreed).
        let _ = (LuckgramAI.shared.transcribe(context: nil, present: nil, audio: audio, mimeType: mimeType)
        |> deliverOnMainQueue).start(next: { transcription in
            // #55: a partial transcript keeps the finished segments and says why the rest is missing.
            completion(transcription.text, transcription.partialError?.localizedMessage)
        }, error: { error in
            completion(nil, error.localizedMessage)
        })
    }
    
    var maxSummaryInputChars: Int {
        return LuckgramSettings.shared.remoteInt("ai.max_input_chars", default: LuckgramCallRecordingLuckgramAI.defaultMaxInputChars)
    }
    
    func summarize(transcript: String, completion: @escaping (String?, String?) -> Void) {
        var done = false
        let _ = (LuckgramAI.shared.chat(context: nil, present: nil, task: .summary, messages: [.user(transcript)], stream: false)
        |> deliverOnMainQueue).start(next: { event in
            if case let .completed(text) = event, !done {
                done = true
                completion(text, nil)
            }
        }, error: { error in
            if !done {
                done = true
                completion(nil, error.localizedMessage)
            }
        })
    }
}
