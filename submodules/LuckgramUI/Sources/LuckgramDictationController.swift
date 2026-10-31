import Foundation
import UIKit
import AVFoundation
import SwiftSignalKit
import Display
import AccountContext

/// spec 17 voice input: records from the microphone with a live level waveform, then transcribes it
/// with `LuckgramAI.transcribe` and, if "AI tidy" is on, cleans it up with `task=writing,
/// effect=dictation`. The text goes to `completion`; the caller inserts it at the cursor. The audio
/// is recorded to a temporary file that is deleted when the sheet closes.
public final class LuckgramDictationController: UIViewController {
    /// Memory guard for one dictation (10 min of 16 kHz mono PCM ≈ 19 MB).
    private static let maxDuration: TimeInterval = 10 * 60

    private enum State {
        case recording
        case working
        case error(String)
    }

    private let context: AccountContext
    private let isDark: Bool
    private let completion: (String) -> Void

    private let statusLabel = UILabel()
    private let waveform = LuckgramDictationWaveformView()
    private let button = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var state: State = .recording
    private var recorder: AVAudioRecorder?
    private var meterTimer: Foundation.Timer?
    private let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lg_dictation_\(UInt64.random(in: 0 ... UInt64.max)).wav")
    private var audio: Data?
    private var disposable: Disposable?
    private var finished = false

    /// Asks for AI consent and microphone access first, then presents the sheet.
    public static func present(context: AccountContext, isDark: Bool, completion: @escaping (String) -> Void) {
        let presentInWindow: (ViewController) -> Void = { c in
            context.sharedContext.mainWindow?.present(c, on: .root)
        }
        let _ = (LuckgramAI.shared.requestConsent(context: context, present: presentInWindow)
        |> deliverOnMainQueue).startStandalone(next: { granted in
            guard granted else {
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    guard allowed else {
                        let alert = UIAlertController(title: nil, message: LuckgramStrings.pick("请在系统设置中允许 Luckgram 使用麦克风。", "Please allow Luckgram to use the microphone in Settings."), preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("好", "OK"), style: .default))
                        alert.overrideUserInterfaceStyle = isDark ? .dark : .light
                        context.sharedContext.mainWindow?.presentNative(alert)
                        return
                    }
                    let controller = LuckgramDictationController(context: context, isDark: isDark, completion: completion)
                    let navigation = UINavigationController(rootViewController: controller)
                    navigation.modalPresentationStyle = .pageSheet
                    navigation.overrideUserInterfaceStyle = isDark ? .dark : .light
                    if let sheet = navigation.sheetPresentationController {
                        sheet.detents = [.medium()]
                        sheet.prefersGrabberVisible = true
                    }
                    navigation.isModalInPresentation = true
                    context.sharedContext.mainWindow?.presentNative(navigation)
                }
            }
        })
    }

    private init(context: AccountContext, isDark: Bool, completion: @escaping (String) -> Void) {
        self.context = context
        self.isDark = isDark
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
        self.meterTimer?.invalidate()
        self.recorder?.stop()
        try? FileManager.default.removeItem(at: self.fileURL)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        self.title = LuckgramStrings.pick("语音输入", "Voice input")
        self.view.backgroundColor = .systemBackground
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: LuckgramStrings.pick("取消", "Cancel"), style: .plain, target: self, action: #selector(self.cancelPressed))

        self.waveform.color = self.view.tintColor
        self.statusLabel.font = UIFont.systemFont(ofSize: 15.0)
        self.statusLabel.textColor = .secondaryLabel
        self.statusLabel.textAlignment = .center
        self.statusLabel.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .large
        self.button.configuration = config
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [self.waveform, self.statusLabel, self.spinner, self.button])
        stack.axis = .vertical
        stack.spacing = 16.0
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 24.0),
            self.waveform.heightAnchor.constraint(equalToConstant: 72.0),
            self.button.heightAnchor.constraint(equalToConstant: 50.0)
        ])

        self.update(.recording)
        self.startRecording()
    }

    private func update(_ state: State) {
        self.state = state
        var config = self.button.configuration ?? UIButton.Configuration.filled()
        switch state {
        case .recording:
            self.statusLabel.text = LuckgramStrings.pick("正在聆听…说完点「停止」", "Listening… tap Stop when done")
            config.title = LuckgramStrings.pick("停止", "Stop")
            self.button.isEnabled = true
            self.spinner.stopAnimating()
            self.spinner.isHidden = true
        case .working:
            self.statusLabel.text = LuckgramStrings.pick("正在转写…", "Transcribing…")
            config.title = LuckgramStrings.pick("停止", "Stop")
            self.button.isEnabled = false
            self.spinner.isHidden = false
            self.spinner.startAnimating()
        case let .error(text):
            self.statusLabel.text = text
            config.title = LuckgramStrings.pick("重试", "Retry")
            self.button.isEnabled = self.audio != nil
            self.spinner.stopAnimating()
            self.spinner.isHidden = true
        }
        self.button.configuration = config
    }

    private func startRecording() {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: self.fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: LuckgramDictationController.maxDuration) else {
                throw NSError(domain: "LuckgramDictation", code: 1)
            }
            self.recorder = recorder
            self.meterTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true, block: { [weak self] _ in
                guard let self, let recorder = self.recorder else {
                    return
                }
                if !recorder.isRecording {
                    // reached maxDuration
                    if case .recording = self.state {
                        self.buttonPressed()
                    }
                    return
                }
                recorder.updateMeters()
                let db = recorder.peakPower(forChannel: 0) // -160 ... 0
                let level = max(0.0, min(1.0, (db + 50.0) / 50.0))
                self.waveform.push(CGFloat(level))
            })
        } catch {
            self.audio = nil
            self.update(.error(LuckgramStrings.pick("无法使用麦克风", "Can't use the microphone")))
        }
    }

    private func stopRecording() {
        self.meterTimer?.invalidate()
        self.meterTimer = nil
        self.recorder?.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc private func buttonPressed() {
        switch self.state {
        case .recording:
            self.stopRecording()
            guard let data = try? Data(contentsOf: self.fileURL), data.count > 44 + 3200 else {
                // nothing (or < 0.1 s) recorded
                self.dismiss(animated: true)
                return
            }
            self.audio = data
            self.transcribe()
        case .error:
            if self.audio != nil {
                self.transcribe()
            }
        case .working:
            break
        }
    }

    @objc private func cancelPressed() {
        self.stopRecording()
        self.disposable?.dispose()
        self.disposable = nil
        self.dismiss(animated: true)
    }

    private var presentAlert: (ViewController) -> Void {
        let context = self.context
        return { c in
            context.sharedContext.mainWindow?.present(c, on: .root)
        }
    }

    private func transcribe() {
        guard let audio = self.audio else {
            return
        }
        self.update(.working)
        let context = self.context
        let present = self.presentAlert
        let tidy = LuckgramSettings.shared.isEnabled(LuckgramFeatures.dictationAITidy)
        self.disposable?.dispose()
        self.disposable = (LuckgramAI.shared.transcribe(context: context, present: present, audio: audio, mimeType: "audio/wav")
        |> mapToSignal { result -> Signal<String, LuckgramAIError> in
            let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                return .single("")
            }
            if !tidy {
                return .single(raw)
            }
            return LuckgramAI.shared.chat(context: context, present: present, task: .writing, effect: "dictation", messages: [.user(raw)], stream: false)
            |> mapToSignal { event -> Signal<String, LuckgramAIError> in
                if case let .completed(text) = event {
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .single(cleaned.isEmpty ? raw : cleaned)
                }
                return .complete()
            }
            // keep the plain transcript rather than losing what was said
            |> `catch` { _ -> Signal<String, LuckgramAIError> in
                return .single(raw)
            }
        }
        |> take(1)
        |> deliverOnMainQueue).startStrict(next: { [weak self] text in
            guard let self else {
                return
            }
            if text.isEmpty {
                self.update(.error(LuckgramStrings.pick("没有识别到文字", "No words recognized")))
                return
            }
            self.finish(text)
        }, error: { [weak self] error in
            guard let self else {
                return
            }
            if error.code == LuckgramAIError.consentDenied || error.code == LuckgramAIError.cancelled {
                self.dismiss(animated: true)
                return
            }
            self.update(.error(error.localizedMessage))
        })
    }

    private func finish(_ text: String) {
        if self.finished {
            return
        }
        self.finished = true
        let completion = self.completion
        self.dismiss(animated: true, completion: {
            completion(text)
        })
    }
}

/// Scrolling bars of recent input levels.
private final class LuckgramDictationWaveformView: UIView {
    var color: UIColor = .systemBlue
    private var levels = [CGFloat](repeating: 0.0, count: 48)
    private var head = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func push(_ level: CGFloat) {
        // perceived loudness: a square root keeps quiet speech visible
        self.levels[self.head] = level.squareRoot()
        self.head = (self.head + 1) % self.levels.count
        self.setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        ctx.setFillColor(self.color.cgColor)
        let n = self.levels.count
        let slot = self.bounds.width / CGFloat(n)
        let barWidth = max(2.0, slot * 0.55)
        let height = self.bounds.height
        for i in 0 ..< n {
            let v = self.levels[(self.head + i) % n]
            let barHeight = max(3.0, v * height)
            let x = slot * CGFloat(i) + slot / 2.0 - barWidth / 2.0
            let bar = CGRect(x: x, y: (height - barHeight) / 2.0, width: barWidth, height: barHeight)
            ctx.addPath(UIBezierPath(roundedRect: bar, cornerRadius: barWidth / 2.0).cgPath)
        }
        ctx.fillPath()
    }
}
