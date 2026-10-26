import Foundation
import Postbox
import TelegramCore
import AccountContext

/// Luckgram: call recording settings.
///
/// Switches are per device and shared by all accounts (spec 00 §5), in UserDefaults under the
/// same keys as Android / the Luckgram feature registry (`call_recording`, …).
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
    
    private static let defaultsPrefix = "luckgram_settings."
    private static var defaults: UserDefaults { UserDefaults.standard }
    
    private static func bool(_ key: String, _ def: Bool) -> Bool {
        let fullKey = defaultsPrefix + key
        if defaults.object(forKey: fullKey) == nil {
            return def
        }
        return defaults.bool(forKey: fullKey)
    }
    
    private static func setBool(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: defaultsPrefix + key)
    }
    
    public static var isEnabled: Bool {
        get { bool(enabledKey, false) }
        set { setBool(enabledKey, newValue) }
    }
    
    public static var isAutoRecord: Bool {
        get { bool(autoRecordKey, false) }
        set { setBool(autoRecordKey, newValue) }
    }
    
    public static var isAiTranscriptEnabled: Bool {
        get { bool(aiTranscriptKey, true) }
        set { setBool(aiTranscriptKey, newValue) }
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
    /// POST /v1/transcribe. Completion on the main thread with the text or an error message.
    func transcribe(audio: Data, mimeType: String, completion: @escaping (String?, String?) -> Void)
    /// POST /v1/chat with task=summary. Completion on the main thread with 3–6 bullet points.
    func summarize(transcript: String, completion: @escaping (String?, String?) -> Void)
}

public enum LuckgramCallRecordingAIRegistry {
    public static let maxTranscribeBytes = 25 * 1024 * 1024
    public static var instance: LuckgramCallRecordingAI?
}
