import Foundation
import UIKit

/// Luckgram specs#145: WeChat-style voice messages. A toggle left of the input field swaps the field
/// for a 「按住 说话」 bar; holding it records with a full-screen overlay (release to send, slide to
/// 「取消」 or 「转文字」). Only with the compact input bar (specs#94) on.
/// Keep the key in sync with Android (`LuckgramVoiceBar.FEATURE_KEY`).
public enum LuckgramVoiceBar {
    public static let featureKey = "wechat_voice_bar"

    public static var isEnabled: Bool {
        return LuckgramCompactInput.isEnabled && LuckgramSettings.shared.isEnabled(featureKey)
    }

    public static var holdToTalk: String { return LuckgramStrings.pick("按住 说话", "Hold to talk") }
    public static var releaseToSend: String { return LuckgramStrings.pick("松开 发送", "Release to send") }
    public static var converting: String { return LuckgramStrings.pick("正在转文字…", "Converting to text…") }
    public static var tooShort: String { return LuckgramStrings.pick("说话时间太短", "Message too short") }
    public static var nothingHeard: String { return LuckgramStrings.pick("没有听到内容", "Nothing was heard") }
    public static var convertFailed: String { return LuckgramStrings.pick("转文字失败", "Couldn't convert to text") }
    public static var switchToTalk: String { return LuckgramStrings.pick("切换到按住说话", "Switch to hold to talk") }
    public static var switchToKeyboard: String { return LuckgramStrings.pick("切换到键盘", "Switch to keyboard") }

    /// Template icon of the toggle left of the field.
    public static func toggleIcon(talkMode: Bool) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 19.0, weight: .regular)
        return UIImage(systemName: talkMode ? "keyboard" : "mic", withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
    }
}

/// The full-screen overlay shown while 「按住 说话」 is held. Display only: the touch stays with the
/// bar, which reports the finger position through `zone`.
public final class LuckgramTalkOverlayView: UIView {
    private static let barCount = 28
    private static let bubbleColor = UIColor(red: 0x95 / 255.0, green: 0xEC / 255.0, blue: 0x69 / 255.0, alpha: 1.0)
    private static let cancelColor = UIColor(red: 0xFA / 255.0, green: 0x51 / 255.0, blue: 0x51 / 255.0, alpha: 1.0)

    private var levels = [CGFloat](repeating: 0.0, count: LuckgramTalkOverlayView.barCount)
    private var startedAt: CFTimeInterval?
    private var timer: Foundation.Timer?

    public var zone: LuckgramVoiceBarLogic.Zone = .send {
        didSet {
            if self.zone != oldValue {
                self.setNeedsDisplay()
            }
        }
    }

    /// The recording is being read back for 「转文字」: no targets, just the bubble.
    public var isConverting: Bool = false {
        didSet {
            if self.isConverting != oldValue {
                self.setNeedsDisplay()
            }
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isUserInteractionEnabled = true
        self.contentMode = .redraw
        self.isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.timer?.invalidate()
    }

    private var arcHeight: CGFloat {
        return 132.0 + self.safeAreaInsets.bottom
    }

    /// Y (in this view) above which the finger is in the cancel / to-text area.
    public var actionLineY: CGFloat {
        return self.bounds.height - self.arcHeight
    }

    /// Recording has really started: the timer runs from here.
    public func start() {
        if self.startedAt != nil {
            return
        }
        self.startedAt = CACurrentMediaTime()
        self.timer = Foundation.Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true, block: { [weak self] _ in
            self?.setNeedsDisplay()
        })
    }

    public var elapsed: Double {
        guard let startedAt = self.startedAt else {
            return 0.0
        }
        return CACurrentMediaTime() - startedAt
    }

    /// `level` is 0...1.
    public func push(level: CGFloat) {
        self.levels.removeFirst()
        self.levels.append(max(0.0, min(1.0, level)))
        self.setNeedsDisplay()
    }

    public func animateIn() {
        self.alpha = 0.0
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 1.0
        })
    }

    public func animateOut() {
        self.timer?.invalidate()
        self.timer = nil
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha = 0.0
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        let w = self.bounds.width
        let h = self.bounds.height
        context.setFillColor(UIColor(white: 0.0, alpha: 0.7).cgColor)
        context.fill(self.bounds)

        let arcTop = h - self.arcHeight
        let zone: LuckgramVoiceBarLogic.Zone = self.isConverting ? .text : self.zone

        // bubble with the live waveform
        let bubbleSize = CGSize(width: zone == .send ? 180.0 : 110.0, height: 68.0)
        var bubbleCenterX = w / 2.0
        if zone == .cancel {
            bubbleCenterX = w * 0.28
        } else if zone == .text {
            bubbleCenterX = w * 0.72
        }
        let bubbleCenterY = arcTop - 190.0
        let bubbleRect = CGRect(x: bubbleCenterX - bubbleSize.width / 2.0, y: bubbleCenterY - bubbleSize.height / 2.0, width: bubbleSize.width, height: bubbleSize.height)
        let bubbleColor = zone == .cancel ? LuckgramTalkOverlayView.cancelColor : LuckgramTalkOverlayView.bubbleColor
        context.setFillColor(bubbleColor.cgColor)
        UIBezierPath(roundedRect: bubbleRect, cornerRadius: 14.0).fill()
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: bubbleCenterX - 7.0, y: bubbleRect.maxY - 1.0))
        tail.addLine(to: CGPoint(x: bubbleCenterX, y: bubbleRect.maxY + 7.0))
        tail.addLine(to: CGPoint(x: bubbleCenterX + 7.0, y: bubbleRect.maxY - 1.0))
        tail.close()
        tail.fill()

        let barWidth: CGFloat = 2.5
        let gap: CGFloat = 2.5
        let shown = min(LuckgramTalkOverlayView.barCount, Int((bubbleSize.width - 28.0) / (barWidth + gap)))
        let total = CGFloat(shown) * barWidth + CGFloat(shown - 1) * gap
        var x = bubbleCenterX - total / 2.0
        context.setFillColor((zone == .cancel ? UIColor.white : UIColor(white: 0.0, alpha: 0.85)).cgColor)
        for i in (LuckgramTalkOverlayView.barCount - shown) ..< LuckgramTalkOverlayView.barCount {
            let barHeight = 4.0 + self.levels[i] * 30.0
            UIBezierPath(roundedRect: CGRect(x: x, y: bubbleCenterY - barHeight / 2.0, width: barWidth, height: barHeight), cornerRadius: barWidth / 2.0).fill()
            x += barWidth + gap
        }

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14.0),
            .foregroundColor: UIColor(white: 1.0, alpha: 0.85)
        ]
        if self.isConverting {
            self.drawCentered(LuckgramVoiceBar.converting, at: CGPoint(x: bubbleCenterX, y: bubbleRect.maxY + 24.0), attributes: labelAttributes)
            return
        }
        if zone == .send, self.startedAt != nil {
            self.drawCentered(LuckgramVoiceBarLogic.formatDuration(self.elapsed), at: CGPoint(x: bubbleCenterX, y: bubbleRect.maxY + 24.0), attributes: labelAttributes)
        }

        // the two targets
        let targetY = arcTop - 70.0
        self.drawTarget(context: context, center: CGPoint(x: w * 0.22, y: targetY), active: zone == .cancel, activeColor: LuckgramTalkOverlayView.cancelColor, activeGlyphColor: .white, glyph: "✕", label: LuckgramStrings.pick("取消", "Cancel"), labelAttributes: labelAttributes)
        self.drawTarget(context: context, center: CGPoint(x: w * 0.78, y: targetY), active: zone == .text, activeColor: .white, activeGlyphColor: .black, glyph: LuckgramStrings.pick("文", "Aa"), label: LuckgramStrings.pick("转文字", "To text"), labelAttributes: labelAttributes)

        // release area
        let arc = UIBezierPath()
        arc.move(to: CGPoint(x: 0.0, y: h))
        arc.addLine(to: CGPoint(x: 0.0, y: arcTop + 36.0))
        arc.addQuadCurve(to: CGPoint(x: w, y: arcTop + 36.0), controlPoint: CGPoint(x: w / 2.0, y: arcTop - 36.0))
        arc.addLine(to: CGPoint(x: w, y: h))
        arc.close()
        context.setFillColor(UIColor(white: zone == .send ? 0.9 : 0.3, alpha: 1.0).cgColor)
        arc.fill()
        if zone == .send {
            self.drawCentered(LuckgramVoiceBar.releaseToSend, at: CGPoint(x: w / 2.0, y: arcTop - 22.0), attributes: labelAttributes)
        }
    }

    private func drawTarget(context: CGContext, center: CGPoint, active: Bool, activeColor: UIColor, activeGlyphColor: UIColor, glyph: String, label: String, labelAttributes: [NSAttributedString.Key: Any]) {
        let radius: CGFloat = active ? 42.0 : 34.0
        context.setFillColor((active ? activeColor : UIColor(white: 0.23, alpha: 1.0)).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0))
        let glyphAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22.0, weight: .semibold),
            .foregroundColor: active ? activeGlyphColor : UIColor(white: 0.72, alpha: 1.0)
        ]
        self.drawCentered(glyph, at: center, attributes: glyphAttributes)
        if active {
            self.drawCentered(label, at: CGPoint(x: center.x, y: center.y - radius - 20.0), attributes: labelAttributes)
        }
    }

    private func drawCentered(_ text: String, at point: CGPoint, attributes: [NSAttributedString.Key: Any]) {
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: point.x - size.width / 2.0, y: point.y - size.height / 2.0))
    }
}
