import Foundation

/// Luckgram: mixes the two sides of a call into one mono 48 kHz stream (same algorithm as
/// Android's CallRecMixer). Only touched from the recorder's serial queue.
final class LuckgramCallRecordingMixer {
    static let rate = 48000
    /// Samples per Opus frame (20 ms), as TGOggOpusWriter expects.
    static let frame = 960
    /// When one side stops delivering, the other is not held back for longer than 300 ms; the
    /// missing side is mixed in as silence.
    static let maxLag = rate * 3 / 10
    
    private var near: [Int16] = []
    private var nearHead = 0
    private var far: [Int16] = []
    private var farHead = 0
    
    private var nearCount: Int { near.count - nearHead }
    private var farCount: Int { far.count - farHead }
    
    func pushNear(_ pcm: Data, sampleRate: Int, channels: Int, muted: Bool) {
        Self.append(&near, pcm: pcm, sampleRate: sampleRate, channels: channels, muted: muted)
    }
    
    func pushFar(_ pcm: Data, sampleRate: Int, channels: Int) {
        Self.append(&far, pcm: pcm, sampleRate: sampleRate, channels: channels, muted: false)
    }
    
    /// Emits every complete frame that can be mixed now.
    func drain(_ sink: ([Int16]) -> Void) {
        while true {
            let n = nearCount
            let f = farCount
            let frame = Self.frame
            if n >= frame && f >= frame {
                sink(mix(useNear: true, useFar: true, count: frame))
            } else if n >= frame && n >= Self.maxLag {
                sink(mix(useNear: true, useFar: false, count: frame))
            } else if f >= frame && f >= Self.maxLag {
                sink(mix(useNear: false, useFar: true, count: frame))
            } else {
                break
            }
        }
        compact()
    }
    
    /// Emits the rest as full frames and returns the final partial frame (0..<frame samples).
    func flush(_ sink: ([Int16]) -> Void) -> [Int16] {
        while max(nearCount, farCount) >= Self.frame {
            sink(mix(useNear: nearCount > 0, useFar: farCount > 0, count: Self.frame))
        }
        let count = max(nearCount, farCount)
        let tail = count > 0 ? mix(useNear: nearCount > 0, useFar: farCount > 0, count: count) : []
        compact()
        return tail
    }
    
    private func mix(useNear: Bool, useFar: Bool, count: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: count)
        let gotNear = useNear ? min(count, nearCount) : 0
        let gotFar = useFar ? min(count, farCount) : 0
        for i in 0 ..< count {
            let a: Int32 = i < gotNear ? Int32(near[nearHead + i]) : 0
            let b: Int32 = i < gotFar ? Int32(far[farHead + i]) : 0
            out[i] = Int16(clamping: a + b)
        }
        nearHead += gotNear
        farHead += gotFar
        return out
    }
    
    private func compact() {
        if nearHead > 48000 {
            near.removeFirst(nearHead)
            nearHead = 0
        }
        if farHead > 48000 {
            far.removeFirst(farHead)
            farHead = 0
        }
    }
    
    private static func append(_ buffer: inout [Int16], pcm: Data, sampleRate: Int, channels: Int, muted: Bool) {
        let channels = max(1, channels)
        let frames = pcm.count / (2 * channels)
        if frames == 0 || sampleRate <= 0 {
            return
        }
        var mono = [Int16](repeating: 0, count: frames)
        if !muted {
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0 ..< frames {
                    var sum: Int32 = 0
                    for c in 0 ..< channels {
                        sum += Int32(Int16(littleEndian: samples[i * channels + c]))
                    }
                    mono[i] = Int16(clamping: sum / Int32(channels))
                }
            }
        }
        if sampleRate == rate {
            buffer.append(contentsOf: mono)
        } else {
            buffer.append(contentsOf: resample(mono, from: sampleRate))
        }
    }
    
    /// Linear resampling of one 10 ms block to 48 kHz.
    static func resample(_ input: [Int16], from fromRate: Int) -> [Int16] {
        let outCount = input.count * rate / fromRate
        if input.isEmpty || outCount == 0 {
            return []
        }
        var out = [Int16](repeating: 0, count: outCount)
        let step = Double(fromRate) / Double(rate)
        for i in 0 ..< outCount {
            let pos = Double(i) * step
            let i0 = min(Int(pos), input.count - 1)
            let i1 = min(i0 + 1, input.count - 1)
            let t = pos - Double(Int(pos))
            out[i] = Int16(clamping: Int((Double(input[i0]) * (1.0 - t) + Double(input[i1]) * t).rounded()))
        }
        return out
    }
}
