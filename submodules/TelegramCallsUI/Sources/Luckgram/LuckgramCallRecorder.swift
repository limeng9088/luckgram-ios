import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramVoip
import OpusBinding

/// Luckgram: records one-on-one calls (spec 04).
///
/// Taps the shared call audio device (microphone + the other side's decoded audio), mixes both
/// into mono 48 kHz and encodes Ogg/Opus in memory. When the recording stops (button, hang-up,
/// the other side hanging up, network failure, the call turning into a group call), whatever was
/// recorded is handed to `LuckgramCallRecordingUploader`.
///
/// Main-thread API; audio work runs on a private serial queue.
public final class LuckgramCallRecorder {
    public static let shared = LuckgramCallRecorder()
    
    /// Recordings shorter than this are dropped (accidental double tap).
    private static let minDuration: Double = 1.0
    
    private final class Session {
        let callId: CallSessionInternalId
        let context: AccountContext
        let peer: EnginePeer
        let startedAt: Double
        let startDate: Date
        let mixer = LuckgramCallRecordingMixer()
        let dataItem = TGDataItem(data: Data())
        let writer = TGOggOpusWriter()
        let isMicMuted = Atomic<Bool>(value: false)
        // Queue-confined.
        var writerStarted = false
        var writeFailed = false
        var stopped = false
        
        init(callId: CallSessionInternalId, context: AccountContext, peer: EnginePeer) {
            self.callId = callId
            self.context = context
            self.peer = peer
            self.startedAt = CFAbsoluteTimeGetCurrent()
            self.startDate = Date()
        }
    }
    
    private let queue = Queue(name: "org.luckgram.callRecorder")
    private var session: Session?
    private var autoHandledCallIds = Set<CallSessionInternalId>()
    private var callDisposables: [CallSessionInternalId: Disposable] = [:]
    private let stateValue = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    /// Emits whether a recording is running.
    public var isRecordingSignal: Signal<Bool, NoError> {
        return self.stateValue.get()
    }
    
    public var isRecording: Bool {
        return self.session != nil
    }
    
    public var elapsed: Double {
        guard let session = self.session else {
            return 0.0
        }
        return CFAbsoluteTimeGetCurrent() - session.startedAt
    }
    
    private init() {
    }
    
    // MARK: Eligibility
    
    /// The record button belongs on one-on-one calls only (not group calls, live streams, or a
    /// private call that was turned into a conference).
    public static func isEligible(_ call: PresentationCall) -> Bool {
        guard let peer = call.peer, case .user = peer else {
            return false
        }
        if call.conferenceStateValue != nil || call.conferenceCall != nil {
            return false
        }
        return true
    }
    
    // MARK: Hooks
    
    /// Hook: PresentationCallImpl init. Follows the call's state for auto-record and to save the
    /// recording when the call ends for any reason.
    func attach(call: PresentationCall) {
        let callId = call.internalId
        let signal = combineLatest(queue: .mainQueue(), call.state, call.isMuted, call.conferenceState)
        self.callDisposables[callId]?.dispose()
        self.callDisposables[callId] = signal.start(next: { [weak self, weak call] state, isMuted, conferenceState in
            guard let self, let call else {
                return
            }
            self.handle(call: call, state: state.state, isMuted: isMuted, isConference: conferenceState != nil)
        })
    }
    
    private func handle(call: PresentationCall, state: PresentationCallState.State, isMuted: Bool, isConference: Bool) {
        let callId = call.internalId
        var ended = false
        var active = false
        switch state {
        case .terminating, .terminated:
            ended = true
        case .active:
            active = true
        default:
            break
        }
        
        if let session = self.session, session.callId == callId {
            let _ = session.isMicMuted.swap(isMuted)
            if ended || isConference || !LuckgramCallRecorder.isEligible(call) {
                self.stop(save: true)
            }
        } else if active && !isConference && LuckgramCallRecorder.isEligible(call)
                    && LuckgramCallRecordingSettings.isEnabled && LuckgramCallRecordingSettings.isAutoRecord
                    && !self.autoHandledCallIds.contains(callId) {
            self.autoHandledCallIds.insert(callId)
            self.start(call: call, isMuted: isMuted)
        }
        
        if ended {
            if case .terminated = state {
                self.callDisposables.removeValue(forKey: callId)?.dispose()
                self.autoHandledCallIds.remove(callId)
            }
        }
    }
    
    // MARK: Control
    
    /// Record button.
    public func toggle(call: PresentationCall) {
        if self.session != nil {
            self.stop(save: true)
            return
        }
        guard LuckgramCallRecordingSettings.isEnabled, LuckgramCallRecorder.isEligible(call) else {
            return
        }
        let _ = (call.state |> take(1) |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, self.session == nil else {
                return
            }
            if case .active = state.state {
                let _ = (call.isMuted |> take(1) |> deliverOnMainQueue).start(next: { [weak self] isMuted in
                    self?.start(call: call, isMuted: isMuted)
                })
            }
        })
    }
    
    private func start(call: PresentationCall, isMuted: Bool) {
        guard self.session == nil, let peer = call.peer else {
            return
        }
        let session = Session(callId: call.internalId, context: call.context, peer: peer)
        let _ = session.isMicMuted.swap(isMuted)
        self.session = session
        self.autoHandledCallIds.insert(call.internalId)
        
        let queue = self.queue
        queue.async {
            session.writerStarted = session.writer.begin(with: session.dataItem)
            if !session.writerStarted {
                Logger.shared.log("LuckgramCallRecorder", "cannot start the Opus writer")
            }
        }
        
        CallAudioRecordingTap.setSink({ isPlayout, pcm, sampleRate, channels in
            // Real-time audio thread: hand off immediately.
            let muted = isPlayout ? false : session.isMicMuted.with { $0 }
            queue.async {
                if session.stopped || !session.writerStarted {
                    return
                }
                if isPlayout {
                    session.mixer.pushFar(pcm, sampleRate: Int(sampleRate), channels: Int(channels))
                } else {
                    // While muted the other side hears nothing, so the recording gets silence.
                    session.mixer.pushNear(pcm, sampleRate: Int(sampleRate), channels: Int(channels), muted: muted)
                }
                session.mixer.drain { frame in
                    LuckgramCallRecorder.write(frame, session: session)
                }
            }
        })
        self.stateValue.set(true)
    }
    
    private static func write(_ frame: [Int16], session: Session) {
        if session.writeFailed {
            return
        }
        var frame = frame
        let ok = frame.withUnsafeMutableBytes { bytes -> Bool in
            return session.writer.writeFrame(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(bytes.count))
        }
        if !ok {
            session.writeFailed = true
        }
    }
    
    private func stop(save: Bool) {
        guard let session = self.session else {
            return
        }
        self.session = nil
        CallAudioRecordingTap.setSink(nil)
        self.stateValue.set(false)
        
        self.queue.async {
            // Runs after every block already queued by the tap, so nothing recorded is lost.
            session.stopped = true
            guard session.writerStarted else {
                return
            }
            var tail = session.mixer.flush { frame in
                LuckgramCallRecorder.write(frame, session: session)
            }
            if tail.isEmpty {
                // 10 ms of silence so the stream always ends with an end-of-stream packet.
                tail = [Int16](repeating: 0, count: LuckgramCallRecordingMixer.frame / 2)
            }
            LuckgramCallRecorder.write(tail, session: session)
            let duration = session.writer.encodedDuration()
            guard let data = session.dataItem.data(), !data.isEmpty else {
                return
            }
            if !save || session.writeFailed || duration < LuckgramCallRecorder.minDuration {
                return
            }
            Queue.mainQueue().async {
                LuckgramCallRecordingUploader.upload(context: session.context, peer: session.peer, data: data, duration: duration, startDate: session.startDate)
            }
        }
    }
}
