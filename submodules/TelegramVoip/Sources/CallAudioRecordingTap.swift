import Foundation
import TgVoipWebrtc

/// Luckgram (call recording): access to the PCM blocks of the shared call audio device.
///
/// The sink gets `(isPlayout, pcm16, sampleRate, channels)` for every 10 ms block: microphone
/// input when `isPlayout` is false, the other side's decoded audio when true. It is invoked on
/// the real-time audio thread, so it must only copy the data and hand it off.
public enum CallAudioRecordingTap {
    public static func setSink(_ sink: ((Bool, Data, Int32, Int32) -> Void)?) {
        if let sink {
            OngoingCallAudioRecordingTap.setSink({ isPlayout, pcm, sampleRate, channels in
                sink(isPlayout, pcm, sampleRate, channels)
            })
        } else {
            OngoingCallAudioRecordingTap.setSink(nil)
        }
    }
}
