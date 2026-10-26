import Foundation
import TelegramPresentationData

/// Luckgram: call recording UI strings in Chinese and English (Telegram has no official Chinese
/// language pack). Chinese is used when the in-app language or the system language is Chinese.
enum LuckgramCallRecordingStrings {
    static func isChinese(_ strings: PresentationStrings? = nil) -> Bool {
        if let strings, strings.primaryComponent.languageCode.lowercased().hasPrefix("zh") {
            return true
        }
        if let preferred = Locale.preferredLanguages.first, preferred.lowercased().hasPrefix("zh") {
            return true
        }
        return false
    }
    
    private static func s(_ zh: String, _ en: String) -> String {
        return isChinese() ? zh : en
    }
    
    // MARK: Settings
    
    static var featureName: String { s("通话录音", "Call Recording") }
    static var featureDescription: String { s("一对一通话中录音，挂断后保存到收藏夹", "Record one-on-one calls and save them to Saved Messages") }
    static var enable: String { s("启用通话录音", "Enable Call Recording") }
    static var enableInfo: String { s("开启后，一对一语音和视频通话界面会出现「录音」按钮。群组通话和直播不支持录音。", "Adds a Record button to one-on-one voice and video calls. Group calls and live streams can't be recorded.") }
    static var legalTitle: String { s("录音前请注意", "Before You Record") }
    static var legalText: String { s("各国和地区对通话录音的法律规定不同，录音前请先告知对方并取得同意。", "Laws on recording calls differ between countries and regions. Tell the other person and get their consent before recording.") }
    static var gotIt: String { s("我知道了", "Got It") }
    static var cancel: String { s("取消", "Cancel") }
    static var autoRecord: String { s("通话接通后自动录音", "Record Automatically") }
    static var autoRecordInfo: String { s("一对一通话接通后自动开始录音，随时可以点按钮停止。", "Starts recording as soon as a one-on-one call connects. Tap the button to stop at any time.") }
    static var aiTranscript: String { s("AI 文字稿", "AI Transcript") }
    static var aiTranscriptInfo: String { s("挂断后生成文字稿和 3–6 条要点总结，回复在录音下面。录音会发送到 Luckgram 的 AI 服务处理。", "After the call, a transcript and a 3–6 point summary are posted as a reply to the recording. The audio is sent to the Luckgram AI service for processing.") }
    static var saveTo: String { s("保存到", "Save To") }
    static var savedMessages: String { s("收藏夹", "Saved Messages") }
    static var chooseChat: String { s("选择聊天", "Choose a Chat") }
    static var resetToSaved: String { s("改回收藏夹", "Use Saved Messages") }
    static var saveToInfo: String { s("录音只保存在你自己的 Telegram 云端（收藏夹或你选的聊天），上传完成后删除本机临时文件。", "Recordings are kept only in your own Telegram cloud (Saved Messages or the chat you pick). The temporary file on this device is deleted once the upload finishes.") }
    
    // MARK: Call screen
    
    static var record: String { s("录音", "Record") }
    static func recording(_ elapsed: String) -> String {
        return isChinese() ? "录音 " + elapsed : "Recording " + elapsed
    }
    static var stopRecording: String { s("停止录音", "Stop recording") }
    
    // MARK: Saved message
    
    static func fileTitle(peerName: String, dateTime: String) -> String {
        return (isChinese() ? "通话 " : "Call ") + peerName + " " + dateTime
    }
    static func caption(peerName: String, duration: String) -> String {
        return isChinese() ? "与 \(peerName) 的通话 · \(duration)" : "Call with \(peerName) · \(duration)"
    }
    static var summaryHeader: String { s("要点总结", "Summary") }
    static var transcriptHeader: String { s("文字稿", "Transcript") }
    static var transcriptContinued: String { s("文字稿（续）", "Transcript (continued)") }
    static var transcriptEmpty: String { s("（没有识别到说话内容）", "(No speech detected)") }
    static var tooLongForTranscript: String { s("录音超过 25 MB，未生成文字稿。", "The recording is larger than 25 MB, so no transcript was made.") }
    static func transcriptFailed(_ reason: String) -> String {
        return isChinese() ? "文字稿生成失败：" + reason : "Couldn't make a transcript: " + reason
    }
}

/// "0:21", "12:04", "1:02:03".
func luckgramFormatDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}
