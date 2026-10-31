import Foundation
import AVFoundation
import CoreMedia
import UIKit

/// Transcodes a square region of a video into an H.264 + AAC mp4 with the parameters Telegram
/// uses for round video messages. Runs on a background queue, reports progress on the main queue
/// and can be cancelled; on cancel or failure the partial output file is removed.
final class LuckgramRoundVideoExporter {
    enum Result {
        case completed(URL)
        case failed
        case cancelled
    }

    private let asset: AVAsset
    private let videoTrack: AVAssetTrack
    private let audioTrack: AVAssetTrack?
    private let cropRect: CGRect          // in display-oriented video pixels
    private let timeRange: CMTimeRange
    let outputSide: Int
    let outputURL: URL

    private let queue = DispatchQueue(label: "luckgram.roundvideo.export")
    private let lock = NSLock()
    private var _cancelled = false

    private var cancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._cancelled
    }

    init(asset: AVAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?, cropRect: CGRect, timeRange: CMTimeRange) {
        self.asset = asset
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.cropRect = cropRect
        self.timeRange = timeRange

        // Same ceiling as Telegram's own video message export (480 px, never upscaled).
        self.outputSide = LuckgramRoundVideoGeometry.outputSide(cropSide: Double(cropRect.width))

        self.outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("luckgram-round-\(UInt64.random(in: 0 ... UInt64.max)).mp4")
    }

    /// Transform that maps the track's natural frame onto display orientation with origin at zero.
    static func normalizedTransform(for track: AVAssetTrack) -> (CGAffineTransform, CGSize) {
        var transform = track.preferredTransform
        let rect = CGRect(origin: .zero, size: track.naturalSize).applying(transform)
        transform = transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return (transform, CGSize(width: abs(rect.width), height: abs(rect.height)))
    }

    func cancel() {
        // The pump loops check the flag and stop; reader and writer are cancelled by `run`.
        self.lock.lock()
        self._cancelled = true
        self.lock.unlock()
    }

    func start(progress: @escaping (Float) -> Void, completion: @escaping (Result) -> Void) {
        self.queue.async {
            let result = self.run(progress: progress)
            if case .completed = result {
            } else {
                try? FileManager.default.removeItem(at: self.outputURL)
            }
            DispatchQueue.main.async {
                if self.cancelled {
                    try? FileManager.default.removeItem(at: self.outputURL)
                    completion(.cancelled)
                } else {
                    completion(result)
                }
            }
        }
    }

    private func run(progress: @escaping (Float) -> Void) -> Result {
        if self.cancelled {
            return .cancelled
        }
        try? FileManager.default.removeItem(at: self.outputURL)

        let side = CGFloat(self.outputSide)
        let (baseTransform, _) = LuckgramRoundVideoExporter.normalizedTransform(for: self.videoTrack)
        let scale = side / self.cropRect.width
        let transform = baseTransform
            .concatenating(CGAffineTransform(translationX: -self.cropRect.minX, y: -self.cropRect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: side, height: side)
        var frameRate = self.videoTrack.nominalFrameRate
        if frameRate <= 0.0 || frameRate > 30.0 {
            frameRate = 30.0
        }
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: self.asset.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: self.videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: self.asset)
            writer = try AVAssetWriter(outputURL: self.outputURL, fileType: .mp4)
        } catch {
            return .failed
        }
        reader.timeRange = self.timeRange
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [self.videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            return .failed
        }
        reader.add(videoOutput)

        let bitrate = LuckgramRoundVideoGeometry.videoBitrate(outputSide: self.outputSide)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.outputSide,
            AVVideoHeightKey: self.outputSide,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate.rounded())
            ] as [String: Any]
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            return .failed
        }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack = self.audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 64000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output) && writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioOutput = output
                audioInput = input
            }
        }

        if self.cancelled {
            return .cancelled
        }

        guard reader.startReading(), writer.startWriting() else {
            reader.cancelReading()
            writer.cancelWriting()
            return self.cancelled ? .cancelled : .failed
        }
        writer.startSession(atSourceTime: self.timeRange.start)

        let group = DispatchGroup()
        let start = self.timeRange.start.seconds
        let duration = max(0.001, self.timeRange.duration.seconds)
        var lastReported: Float = -1.0

        group.enter()
        let videoQueue = DispatchQueue(label: "luckgram.roundvideo.video")
        var videoFinished = false
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
            if videoFinished {
                return
            }
            while videoInput.isReadyForMoreMediaData {
                if self?.cancelled ?? true {
                    videoFinished = true
                    if writer.status == .writing { videoInput.markAsFinished() }
                    group.leave()
                    return
                }
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoFinished = true
                    if writer.status == .writing { videoInput.markAsFinished() }
                    group.leave()
                    return
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if !videoInput.append(sample) {
                    videoFinished = true
                    if writer.status == .writing { videoInput.markAsFinished() }
                    group.leave()
                    return
                }
                let value = Float(max(0.0, min(1.0, (time - start) / duration)))
                if value - lastReported >= 0.01 {
                    lastReported = value
                    DispatchQueue.main.async {
                        progress(value)
                    }
                }
            }
        }

        if let audioOutput, let audioInput {
            group.enter()
            let audioQueue = DispatchQueue(label: "luckgram.roundvideo.audio")
            var audioFinished = false
            audioInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
                if audioFinished {
                    return
                }
                while audioInput.isReadyForMoreMediaData {
                    if self?.cancelled ?? true {
                        audioFinished = true
                        if writer.status == .writing { audioInput.markAsFinished() }
                        group.leave()
                        return
                    }
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioFinished = true
                        if writer.status == .writing { audioInput.markAsFinished() }
                        group.leave()
                        return
                    }
                    if !audioInput.append(sample) {
                        audioFinished = true
                        if writer.status == .writing { audioInput.markAsFinished() }
                        group.leave()
                        return
                    }
                }
            }
        }

        // Wait for both pumps (they stop early when cancelled), never hang on a failed writer.
        while group.wait(timeout: .now() + 0.2) == .timedOut {
            if writer.status == .failed || reader.status == .failed {
                break
            }
        }

        if self.cancelled {
            reader.cancelReading()
            writer.cancelWriting()
            return .cancelled
        }
        if reader.status == .failed || writer.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            return .failed
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        if self.cancelled {
            return .cancelled
        }
        if writer.status != .completed {
            return .failed
        }
        return .completed(self.outputURL)
    }
}
