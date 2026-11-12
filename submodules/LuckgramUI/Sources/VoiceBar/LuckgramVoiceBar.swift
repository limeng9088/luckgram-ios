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
    public static var voice: String { return LuckgramStrings.pick("语音", "Voice") }
    public static var cancel: String { return LuckgramStrings.pick("取消", "Cancel") }
    public static var slideForText: String { return LuckgramStrings.pick("滑到这里 转文字", "Slide here for text") }
    public static var releaseToCancel: String { return LuckgramStrings.pick("松手 取消", "Release to cancel") }
    public static var releaseToEdit: String { return LuckgramStrings.pick("松手 编辑文字", "Release to edit text") }
    public static var releaseToConvert: String { return LuckgramStrings.pick("松手后转成文字", "Release to convert to text") }
    public static var tapToCancel: String { return LuckgramStrings.pick("轻点取消", "Tap to cancel") }
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
///
/// Layout, bottom up: the release area (an arc, 「松开 发送」), two tilted pills (「取消」 left,
/// 「滑到这里 转文字」 right) and the voice bubble, which is wide and green while sending, a small red
/// square over 「取消」, and a full-width text bubble over 「转文字」.
public final class LuckgramTalkOverlayView: UIView {
    private static let barCount = 24
    private static let tilt: CGFloat = 7.0 * .pi / 180.0

    private var levels = [CGFloat](repeating: 0.0, count: LuckgramTalkOverlayView.barCount)
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0.0

    // animated towards the current zone's values
    private var laidOut = false
    private var bubbleLeft: CGFloat = 0.0
    private var bubbleRight: CGFloat = 0.0
    private var bubbleTop: CGFloat = 0.0
    private var bubbleTailX: CGFloat = 0.0
    private var cancelActive: CGFloat = 0.0
    private var textActive: CGFloat = 0.0
    private var sendActive: CGFloat = 1.0

    public var zone: LuckgramVoiceBarLogic.Zone = .send {
        didSet {
            if self.zone != oldValue {
                self.setNeedsDisplay()
            }
        }
    }

    /// The recording is being converted to text: only the text bubble stays; a tap calls `tapped`.
    public var isConverting: Bool = false {
        didSet {
            if self.isConverting != oldValue {
                self.setNeedsDisplay()
            }
        }
    }

    public var tapped: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isUserInteractionEnabled = true
        self.contentMode = .redraw
        self.isAccessibilityElement = false
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        self.displayLink?.invalidate()
        self.displayLink = nil
        if newWindow != nil {
            let displayLink = CADisplayLink(target: LuckgramTalkOverlayLinkTarget(self), selector: #selector(LuckgramTalkOverlayLinkTarget.tick))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
    }

    @objc private func tapGesture() {
        if self.isConverting {
            self.tapped?()
        }
    }

    fileprivate func tick() {
        self.setNeedsDisplay()
    }

    /// Y (in this view) above which the finger is in the cancel / to-text area.
    public var actionLineY: CGFloat {
        return self.bounds.height - 118.0 - self.safeAreaInsets.bottom
    }

    /// Recording has really started.
    public func start() {
        self.setNeedsDisplay()
    }

    /// `level` is 0...1.
    public func push(level: CGFloat) {
        self.levels.removeFirst()
        self.levels.append(max(0.0, min(1.0, level)))
    }

    public func animateIn() {
        self.alpha = 0.0
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 1.0
        })
    }

    public func animateOut() {
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha = 0.0
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    private static func blend(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
        return from + (to - from) * t
    }

    private static func gray(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat, alpha: CGFloat = 1.0) -> UIColor {
        return UIColor(white: blend(from, to, t), alpha: alpha)
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        let now = CACurrentMediaTime()
        let dt = self.lastFrame == 0.0 ? 0.016 : min(0.05, now - self.lastFrame)
        self.lastFrame = now

        let w = self.bounds.width
        let h = self.bounds.height
        if w <= 0.0 || h <= 0.0 {
            return
        }
        let bottomInset = self.safeAreaInsets.bottom
        let zone: LuckgramVoiceBarLogic.Zone = self.isConverting ? .text : self.zone
        let cancel = zone == .cancel
        let text = zone == .text
        let send = zone == .send

        // targets for this zone
        let pillCenterY = h - 160.0 - bottomInset
        let pillHeight: CGFloat = 72.0
        let bubbleBottom = min(h * 0.613, pillCenterY - pillHeight / 2.0 - 96.0)
        let targetLeft: CGFloat
        let targetRight: CGFloat
        let targetTop: CGFloat
        let targetTail: CGFloat
        if cancel {
            targetLeft = 36.0
            targetRight = targetLeft + 78.0
            targetTop = bubbleBottom - 78.0
            targetTail = (targetLeft + targetRight) / 2.0
        } else if text {
            targetLeft = 16.0
            targetRight = w - 16.0
            targetTop = bubbleBottom - 92.0
            targetTail = w * 0.76
        } else {
            let bubbleWidth = min(w * 0.58, 240.0)
            targetLeft = (w - bubbleWidth) / 2.0
            targetRight = targetLeft + bubbleWidth
            targetTop = bubbleBottom - 76.0
            targetTail = w / 2.0
        }
        if !self.laidOut {
            self.laidOut = true
            self.bubbleLeft = targetLeft
            self.bubbleRight = targetRight
            self.bubbleTop = targetTop
            self.bubbleTailX = targetTail
        }
        let k = CGFloat(1.0 - exp(-dt / 0.055))
        self.bubbleLeft += (targetLeft - self.bubbleLeft) * k
        self.bubbleRight += (targetRight - self.bubbleRight) * k
        self.bubbleTop += (targetTop - self.bubbleTop) * k
        self.bubbleTailX += (targetTail - self.bubbleTailX) * k
        self.cancelActive += ((cancel ? 1.0 : 0.0) - self.cancelActive) * k
        self.textActive += ((text ? 1.0 : 0.0) - self.textActive) * k
        self.sendActive += ((send ? 1.0 : 0.0) - self.sendActive) * k

        context.setFillColor(UIColor(white: 0.0, alpha: 0.6).cgColor)
        context.fill(self.bounds)

        // ---- bubble (#95EC69 → #FA5151 over 「取消」)
        let c = self.cancelActive
        let bubbleColor = UIColor(
            red: LuckgramTalkOverlayView.blend(0x95, 0xFA, c) / 255.0,
            green: LuckgramTalkOverlayView.blend(0xEC, 0x51, c) / 255.0,
            blue: LuckgramTalkOverlayView.blend(0x69, 0x51, c) / 255.0,
            alpha: 1.0
        )
        context.setFillColor(bubbleColor.cgColor)
        let bubbleRect = CGRect(x: self.bubbleLeft, y: self.bubbleTop, width: self.bubbleRight - self.bubbleLeft, height: bubbleBottom - self.bubbleTop)
        UIBezierPath(roundedRect: bubbleRect, cornerRadius: 16.0).fill()
        let tailX = max(self.bubbleLeft + 22.0, min(self.bubbleRight - 22.0, self.bubbleTailX))
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: tailX - 9.0, y: bubbleBottom - 1.0))
        tail.addLine(to: CGPoint(x: tailX, y: bubbleBottom + 9.0))
        tail.addLine(to: CGPoint(x: tailX + 9.0, y: bubbleBottom - 1.0))
        tail.close()
        tail.fill()

        let barWidth: CGFloat = 2.0
        let gap: CGFloat = 1.5
        context.setFillColor(UIColor(white: 0.0, alpha: 0.42).cgColor)
        if text {
            // what will happen, then the small live waveform bottom right
            let label = self.isConverting ? LuckgramVoiceBar.converting : LuckgramVoiceBar.releaseToConvert
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18.0),
                .foregroundColor: UIColor(white: 0.0, alpha: (self.isConverting ? 0.9 : 0.45) * self.textActive)
            ]
            NSAttributedString(string: label, attributes: attributes).draw(at: CGPoint(x: self.bubbleLeft + 20.0, y: self.bubbleTop + 18.0))
            if !self.isConverting {
                context.setFillColor(UIColor(white: 0.0, alpha: 0.42).cgColor)
                self.drawBars(x: self.bubbleRight - 20.0 - (12.0 * barWidth + 11.0 * gap), centerY: bubbleBottom - 20.0, count: 12, barWidth: barWidth, gap: gap, minHeight: 2.0, maxHeight: 10.0)
            }
        } else {
            let count = cancel ? 8 : LuckgramTalkOverlayView.barCount
            let total = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
            self.drawBars(x: bubbleRect.midX - total / 2.0, centerY: bubbleRect.midY, count: count, barWidth: barWidth, gap: gap, minHeight: 3.0, maxHeight: cancel ? 14.0 : 22.0)
        }

        if self.isConverting {
            self.drawCentered(LuckgramVoiceBar.tapToCancel, at: CGPoint(x: w / 2.0, y: bubbleBottom + 36.0), attributes: [
                .font: UIFont.systemFont(ofSize: 14.0),
                .foregroundColor: UIColor(white: 1.0, alpha: 0.6)
            ])
            return
        }

        // ---- the two pills
        self.drawPill(context: context, left: true, innerX: w * 0.47, centerY: pillCenterY, height: pillHeight, textX: w * 0.22, active: self.cancelActive, label: LuckgramVoiceBar.cancel, hint: LuckgramVoiceBar.releaseToCancel)
        self.drawPill(context: context, left: false, innerX: w * 0.53, centerY: pillCenterY, height: pillHeight, textX: w * 0.77, active: self.textActive, label: LuckgramVoiceBar.slideForText, hint: LuckgramVoiceBar.releaseToEdit)

        // ---- release area
        let apex = h - 112.0 - bottomInset
        let edge = h - 90.0 - bottomInset
        let arc = UIBezierPath()
        arc.move(to: CGPoint(x: 0.0, y: h))
        arc.addLine(to: CGPoint(x: 0.0, y: edge))
        arc.addQuadCurve(to: CGPoint(x: w, y: edge), controlPoint: CGPoint(x: w / 2.0, y: 2.0 * apex - edge))
        arc.addLine(to: CGPoint(x: w, y: h))
        arc.close()
        context.setFillColor(UIColor(white: 0.29, alpha: 1.0).cgColor)
        arc.fill()
        if self.sendActive > 0.01 {
            context.saveGState()
            arc.addClip()
            context.setAlpha(self.sendActive)
            let colors = [UIColor(white: 0.87, alpha: 1.0).cgColor, UIColor(white: 0.61, alpha: 1.0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: apex), end: CGPoint(x: 0.0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
        }
        let arcTextY = h - 68.0 - bottomInset
        self.drawCentered(LuckgramVoiceBar.releaseToSend, at: CGPoint(x: w / 2.0, y: arcTextY), attributes: [
            .font: UIFont.systemFont(ofSize: 17.0, weight: .semibold),
            .foregroundColor: UIColor(white: 0.09, alpha: self.sendActive)
        ])
        self.drawCentered(LuckgramVoiceBar.voice, at: CGPoint(x: w / 2.0, y: arcTextY + 10.0), attributes: [
            .font: UIFont.systemFont(ofSize: 16.0, weight: .semibold),
            .foregroundColor: UIColor(white: 0.77, alpha: 1.0 - self.sendActive)
        ])
    }

    /// The newest `count` levels, left to right, centered on `centerY`.
    private func drawBars(x: CGFloat, centerY: CGFloat, count: Int, barWidth: CGFloat, gap: CGFloat, minHeight: CGFloat, maxHeight: CGFloat) {
        var x = x
        for i in (LuckgramTalkOverlayView.barCount - count) ..< LuckgramTalkOverlayView.barCount {
            let barHeight = minHeight + self.levels[i] * (maxHeight - minHeight)
            UIBezierPath(roundedRect: CGRect(x: x, y: centerY - barHeight / 2.0, width: barWidth, height: barHeight), cornerRadius: barWidth / 2.0).fill()
            x += barWidth + gap
        }
    }

    /// A pill running off the screen edge, tilted up towards the middle. `innerX` is its end near
    /// the middle, `textX` where its label is centered, `active` 0...1.
    private func drawPill(context: CGContext, left: Bool, innerX: CGFloat, centerY: CGFloat, height: CGFloat, textX: CGFloat, active: CGFloat, label: String, hint: String) {
        context.saveGState()
        context.translateBy(x: innerX, y: centerY)
        context.rotate(by: left ? -LuckgramTalkOverlayView.tilt : LuckgramTalkOverlayView.tilt)
        context.translateBy(x: -innerX, y: -centerY)
        let grow = 4.0 * active
        let half = height / 2.0 + grow
        let pillRect: CGRect
        if left {
            pillRect = CGRect(x: -80.0, y: centerY - half, width: innerX + grow + 80.0, height: half * 2.0)
        } else {
            pillRect = CGRect(x: innerX - grow, y: centerY - half, width: self.bounds.width + 80.0 - (innerX - grow), height: half * 2.0)
        }
        context.setFillColor(LuckgramTalkOverlayView.gray(0.35, 0.89, active).cgColor)
        UIBezierPath(roundedRect: pillRect, cornerRadius: half).fill()
        self.drawCentered(label, at: CGPoint(x: textX, y: centerY), attributes: [
            .font: UIFont.systemFont(ofSize: 16.0, weight: .semibold),
            .foregroundColor: LuckgramTalkOverlayView.gray(0.93, 0.07, active)
        ])
        if active > 0.01 {
            self.drawCentered(hint, at: CGPoint(x: textX, y: centerY - half - 18.0), attributes: [
                .font: UIFont.systemFont(ofSize: 14.0),
                .foregroundColor: UIColor(white: 0.72, alpha: active)
            ])
        }
        context.restoreGState()
    }

    private func drawCentered(_ text: String, at point: CGPoint, attributes: [NSAttributedString.Key: Any]) {
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: point.x - size.width / 2.0, y: point.y - size.height / 2.0))
    }
}

/// Keeps the display link from retaining the overlay.
private final class LuckgramTalkOverlayLinkTarget: NSObject {
    private weak var view: LuckgramTalkOverlayView?

    init(_ view: LuckgramTalkOverlayView) {
        self.view = view
    }

    @objc func tick() {
        self.view?.tick()
    }
}
