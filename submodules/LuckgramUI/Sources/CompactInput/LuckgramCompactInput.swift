import Foundation
import UIKit

/// Luckgram specs#94: WeChat-style input bar. When on, the paperclip becomes 「+」 and the Luckgram
/// input buttons (quick replies, voice input, AI writing, translate) move into the 「+」 panel that
/// takes the keyboard's place. Keep the key in sync with Android (`LuckgramCompactInput.FEATURE_KEY`).
public enum LuckgramCompactInput {
    public static let featureKey = "compact_input_bar"

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(featureKey)
    }

    /// The 「+」 glyph for the attachment button (template image, tinted by the panel).
    public static func plusIcon() -> UIImage? {
        let size = CGSize(width: 24.0, height: 24.0)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(1.9)
            cg.setLineCap(.round)
            cg.move(to: CGPoint(x: 12.0, y: 4.5))
            cg.addLine(to: CGPoint(x: 12.0, y: 19.5))
            cg.move(to: CGPoint(x: 4.5, y: 12.0))
            cg.addLine(to: CGPoint(x: 19.5, y: 12.0))
            cg.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// One cell of the 「+」 panel. The order here is the order on screen (specs#94 需求 2).
public enum LuckgramPlusAction: CaseIterable {
    /// Emoji and stickers: the bar itself has no emoji button while the 「+」 panel is on.
    case emoji
    case gallery
    case camera
    case file
    case location
    case contact
    case poll
    case quickReplies
    case dictation
    case aiWriting
    case translate

    public var title: String {
        switch self {
        case .emoji: return LuckgramStrings.pick("表情", "Emoji")
        case .gallery: return LuckgramStrings.pick("相册", "Gallery")
        case .camera: return LuckgramStrings.pick("拍摄", "Camera")
        case .file: return LuckgramStrings.pick("文件", "File")
        case .location: return LuckgramStrings.pick("位置", "Location")
        case .contact: return LuckgramStrings.pick("联系人", "Contact")
        case .poll: return LuckgramStrings.pick("投票", "Poll")
        case .quickReplies: return LuckgramStrings.pick("快捷回复", "Quick replies")
        case .dictation: return LuckgramStrings.pick("语音输入", "Voice input")
        case .aiWriting: return LuckgramStrings.pick("AI 写作", "AI writing")
        case .translate: return LuckgramStrings.pick("翻译", "Translate")
        }
    }

    public var systemImageName: String {
        switch self {
        case .emoji: return "face.smiling"
        case .gallery: return "photo.on.rectangle"
        case .camera: return "camera"
        case .file: return "doc"
        case .location: return "location"
        case .contact: return "person.crop.circle"
        case .poll: return "chart.bar.xaxis"
        case .quickReplies: return "text.bubble"
        case .dictation: return "waveform.and.mic"
        case .aiWriting: return "sparkles"
        case .translate: return "character.bubble"
        }
    }
}
