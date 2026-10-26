import Foundation
import UIKit
import SwiftSignalKit
import AccountContext

/// Luckgram: the "录音 / 录音 0:21" pill shown under the call status (PrivateCallScreen's
/// `luckgramAccessoryView`). Hides itself unless the call is a connected one-on-one call with the
/// feature switched on (or a recording is already running).
final class LuckgramCallRecordButton: UIControl {
    private static let idleColor = UIColor(white: 1.0, alpha: 0.2)
    private static let recordingColor = UIColor(red: 0.898, green: 0.224, blue: 0.231, alpha: 1.0)
    
    private let call: PresentationCall
    private let label = UILabel()
    private let dot = UIView()
    private var stateDisposable: Disposable?
    private var timer: Foundation.Timer?
    private var isCallActive = false
    private var isRecording = false
    
    /// Called when size or visibility changed and the call screen has to relayout.
    var layoutUpdated: (() -> Void)?
    
    init(call: PresentationCall) {
        self.call = call
        super.init(frame: CGRect())
        
        self.layer.cornerRadius = 16.0
        self.clipsToBounds = true
        self.label.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        self.label.textColor = .white
        self.label.textAlignment = .center
        self.label.isUserInteractionEnabled = false
        self.addSubview(self.label)
        self.dot.backgroundColor = .white
        self.dot.layer.cornerRadius = 4.0
        self.dot.isUserInteractionEnabled = false
        self.addSubview(self.dot)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
        
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        
        self.stateDisposable = (combineLatest(queue: .mainQueue(), call.state, call.conferenceState, LuckgramCallRecorder.shared.isRecordingSignal)
        |> deliverOnMainQueue).start(next: { [weak self] state, _, isRecording in
            guard let self else {
                return
            }
            if case .active = state.state {
                self.isCallActive = true
            } else {
                self.isCallActive = false
            }
            self.isRecording = isRecording
            self.updateTimer()
            self.update()
        })
        self.update()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.stateDisposable?.dispose()
        self.timer?.invalidate()
    }
    
    @objc private func pressed() {
        LuckgramCallRecorder.shared.toggle(call: self.call)
    }
    
    private func updateTimer() {
        if self.isRecording {
            if self.timer == nil {
                self.timer = Foundation.Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: { [weak self] _ in
                    self?.update()
                })
            }
        } else {
            self.timer?.invalidate()
            self.timer = nil
        }
    }
    
    private var shouldBeVisible: Bool {
        if self.isRecording {
            return true
        }
        return LuckgramCallRecordingSettings.isEnabled && self.isCallActive && LuckgramCallRecorder.isEligible(self.call)
    }
    
    private func update() {
        let previousText = self.label.text
        let previousHidden = self.isHidden
        if self.isRecording {
            let seconds = Int(LuckgramCallRecorder.shared.elapsed)
            self.label.text = LuckgramCallRecordingStrings.recording(luckgramFormatDuration(seconds))
            self.accessibilityLabel = LuckgramCallRecordingStrings.stopRecording
            self.backgroundColor = LuckgramCallRecordButton.recordingColor
            self.dot.alpha = (Int(CFAbsoluteTimeGetCurrent() * 2.0) % 2 == 0) ? 1.0 : 0.45
        } else {
            self.label.text = LuckgramCallRecordingStrings.record
            self.accessibilityLabel = LuckgramCallRecordingStrings.record
            self.backgroundColor = LuckgramCallRecordButton.idleColor
            self.dot.alpha = 1.0
        }
        self.isHidden = !self.shouldBeVisible
        if previousText != self.label.text || previousHidden != self.isHidden {
            self.setNeedsLayout()
            self.layoutUpdated?()
        }
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelSize = self.label.sizeThatFits(CGSize(width: max(1.0, size.width - 44.0), height: 32.0))
        return CGSize(width: max(88.0, ceil(labelSize.width) + 28.0 + 16.0), height: 32.0)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        self.dot.frame = CGRect(x: 14.0, y: floor((self.bounds.height - 8.0) * 0.5), width: 8.0, height: 8.0)
        self.label.frame = CGRect(x: 28.0, y: 0.0, width: max(0.0, self.bounds.width - 28.0 - 12.0), height: self.bounds.height)
    }
}
