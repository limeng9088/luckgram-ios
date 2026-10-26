import Foundation
import UIKit
import AVFoundation
import Photos
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import PresentationDataUtils

/// Crop page of "send gallery video as round video": a circular viewfinder over the video (drag to
/// move, pinch to zoom), a range selector when the video is longer than 60 seconds, then a
/// cancellable conversion whose result is handed to `completion` as a ready round video message.
public final class LuckgramRoundVideoScreen: ViewController {
    private let context: AccountContext
    private let phAsset: PHAsset
    private let completion: (EnqueueMessage) -> Void
    private let strings: PresentationStrings

    private var avAsset: AVAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var displaySize = CGSize()
    private var duration: Double = 0.0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var exporter: LuckgramRoundVideoExporter?
    private var didSend = false

    private let titleLabel = UILabel()
    private let videoContainer = UIView()
    private let playerView = LuckgramPlayerView()
    private let overlayLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let hintLabel = UILabel()
    private let rangeView = LuckgramRangeView()
    private let rangeLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .custom)
    private let progressPanel = UIView()
    private let progressLabel = UILabel()
    private let progressCancelButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .whiteLarge)

    private var validLayout: ContainerViewLayout?

    // viewfinder geometry, in videoContainer coordinates
    private var circleCenter = CGPoint()
    private var circleDiameter: CGFloat = 0.0
    private var baseScale: CGFloat = 1.0
    private var zoom: CGFloat = 1.0
    private var offset = CGPoint()
    private var pinchStartZoom: CGFloat = 1.0

    private var rangeStart: Double = 0.0
    private var rangeEnd: Double = 0.0

    public init(context: AccountContext, asset: PHAsset, completion: @escaping (EnqueueMessage) -> Void) {
        self.context = context
        self.phAsset = asset
        self.completion = completion
        self.strings = context.sharedContext.currentPresentationData.with { $0 }.strings

        super.init(navigationBarPresentationData: nil)

        self.statusBar.statusBarStyle = .White
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.exporter?.cancel()
        if let timeObserver = self.timeObserver {
            self.player?.removeTimeObserver(timeObserver)
        }
        self.player?.pause()
        NotificationCenter.default.removeObserver(self)
    }

    private func string(_ key: LuckgramRoundVideo.StringKey) -> String {
        return LuckgramRoundVideo.string(key, self.strings)
    }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .black
        self.displayNodeDidLoad()
    }

    override public func displayNodeDidLoad() {
        super.displayNodeDidLoad()
        let view = self.displayNode.view

        self.titleLabel.text = self.string(.title)
        self.titleLabel.textColor = .white
        self.titleLabel.font = UIFont.boldSystemFont(ofSize: 17.0)
        self.titleLabel.textAlignment = .center
        view.addSubview(self.titleLabel)

        self.videoContainer.clipsToBounds = true
        self.videoContainer.addSubview(self.playerView)
        self.overlayLayer.fillRule = .evenOdd
        self.overlayLayer.fillColor = UIColor(white: 0.0, alpha: 0.7).cgColor
        self.videoContainer.layer.addSublayer(self.overlayLayer)
        self.ringLayer.fillColor = UIColor.clear.cgColor
        self.ringLayer.strokeColor = UIColor(white: 1.0, alpha: 0.8).cgColor
        self.ringLayer.lineWidth = 2.0
        self.videoContainer.layer.addSublayer(self.ringLayer)
        self.progressLayer.fillColor = UIColor.clear.cgColor
        self.progressLayer.strokeColor = UIColor(rgb: 0x2ea6ff).cgColor
        self.progressLayer.lineWidth = 4.0
        self.progressLayer.lineCap = .round
        self.progressLayer.strokeEnd = 0.0
        self.progressLayer.isHidden = true
        self.videoContainer.layer.addSublayer(self.progressLayer)
        view.addSubview(self.videoContainer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(self.handlePinch(_:)))
        pan.delegate = self.gestureDelegate
        pinch.delegate = self.gestureDelegate
        self.videoContainer.addGestureRecognizer(pan)
        self.videoContainer.addGestureRecognizer(pinch)

        self.hintLabel.text = self.string(.hint)
        self.hintLabel.textColor = UIColor(white: 1.0, alpha: 0.7)
        self.hintLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.hintLabel.textAlignment = .center
        self.hintLabel.numberOfLines = 2
        view.addSubview(self.hintLabel)

        self.rangeView.isHidden = true
        self.rangeView.rangeChanged = { [weak self] start, end, seekToEnd in
            guard let self else {
                return
            }
            self.rangeStart = start
            self.rangeEnd = end
            self.updateRangeLabel()
            self.player?.pause()
            self.player?.seek(to: CMTime(seconds: seekToEnd ? end : start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        self.rangeView.rangeChangeEnded = { [weak self] in
            guard let self else {
                return
            }
            self.player?.seek(to: CMTime(seconds: self.rangeStart, preferredTimescale: 600))
            self.player?.play()
        }
        view.addSubview(self.rangeView)

        self.rangeLabel.textColor = .white
        self.rangeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .regular)
        self.rangeLabel.textAlignment = .center
        self.rangeLabel.isHidden = true
        view.addSubview(self.rangeLabel)

        self.cancelButton.setTitle(self.string(.cancel), for: .normal)
        self.cancelButton.setTitleColor(.white, for: .normal)
        self.cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0)
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
        view.addSubview(self.cancelButton)

        self.sendButton.backgroundColor = UIColor(rgb: 0x2ea6ff)
        self.sendButton.layer.cornerRadius = 28.0
        self.sendButton.setImage(generateSendArrow(), for: .normal)
        self.sendButton.accessibilityLabel = self.string(.send)
        self.sendButton.addTarget(self, action: #selector(self.sendPressed), for: .touchUpInside)
        self.sendButton.isEnabled = false
        self.sendButton.alpha = 0.5
        view.addSubview(self.sendButton)

        self.progressPanel.backgroundColor = .black
        self.progressPanel.isHidden = true
        self.progressLabel.textColor = .white
        self.progressLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15.0, weight: .regular)
        self.progressLabel.textAlignment = .center
        self.progressPanel.addSubview(self.progressLabel)
        self.progressCancelButton.setTitle(self.string(.cancel), for: .normal)
        self.progressCancelButton.setTitleColor(.white, for: .normal)
        self.progressCancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0)
        self.progressCancelButton.backgroundColor = UIColor(white: 1.0, alpha: 0.15)
        self.progressCancelButton.layer.cornerRadius = 10.0
        self.progressCancelButton.addTarget(self, action: #selector(self.cancelConversion), for: .touchUpInside)
        self.progressPanel.addSubview(self.progressCancelButton)
        view.addSubview(self.progressPanel)

        self.activityIndicator.startAnimating()
        view.addSubview(self.activityIndicator)

        self.loadAsset()
    }

    private lazy var gestureDelegate: LuckgramSimultaneousGestureDelegate = LuckgramSimultaneousGestureDelegate()

    private func loadAsset() {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        PHImageManager.default().requestAVAsset(forVideo: self.phAsset, options: options, resultHandler: { [weak self] asset, _, _ in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard let asset, let videoTrack = asset.tracks(withMediaType: .video).first else {
                    self.showFailure(dismiss: true)
                    return
                }
                self.didLoad(asset: asset, videoTrack: videoTrack, audioTrack: asset.tracks(withMediaType: .audio).first)
            }
        })
    }

    private func didLoad(asset: AVAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?) {
        self.avAsset = asset
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.displaySize = LuckgramRoundVideoExporter.normalizedTransform(for: videoTrack).1
        self.duration = max(0.0, asset.duration.seconds.isFinite ? asset.duration.seconds : 0.0)
        if self.displaySize.width < 1.0 || self.displaySize.height < 1.0 || self.duration <= 0.0 {
            self.showFailure(dismiss: true)
            return
        }
        let initialRange = LuckgramRoundVideoGeometry.initialRange(duration: self.duration)
        self.rangeStart = initialRange.start
        self.rangeEnd = initialRange.end

        self.activityIndicator.stopAnimating()
        self.activityIndicator.isHidden = true
        self.sendButton.isEnabled = true
        self.sendButton.alpha = 1.0

        if LuckgramRoundVideoGeometry.needsRange(duration: self.duration) {
            self.rangeView.isHidden = false
            self.rangeLabel.isHidden = false
            self.rangeView.configure(asset: asset, duration: self.duration, maxLength: LuckgramRoundVideo.maxDuration)
            self.updateRangeLabel()
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        self.player = player
        self.playerView.playerLayer.player = player
        self.playerView.playerLayer.videoGravity = .resize
        NotificationCenter.default.addObserver(self, selector: #selector(self.playerItemDidEnd), name: .AVPlayerItemDidPlayToEndTime, object: item)
        self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main, using: { [weak self] time in
            guard let self, let player = self.player else {
                return
            }
            let seconds = time.seconds
            if !self.rangeView.isHidden {
                self.rangeView.setPlaybackPosition(seconds)
            }
            if !self.rangeView.isTracking && player.rate > 0.0 && seconds >= self.rangeEnd - 0.03 {
                player.seek(to: CMTime(seconds: self.rangeStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        })
        player.play()

        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .immediate)
        }
    }

    @objc private func playerItemDidEnd() {
        self.player?.seek(to: CMTime(seconds: self.rangeStart, preferredTimescale: 600))
        self.player?.play()
    }

    private func updateRangeLabel() {
        let length = max(0, Int((self.rangeEnd - self.rangeStart).rounded()))
        let text = String(format: "%d:%02d", length / 60, length % 60)
        self.rangeLabel.text = String(format: self.string(.selected), text)
    }

    private func showFailure(dismiss: Bool) {
        let alert = textAlertController(context: self.context, title: nil, text: self.string(.failed), actions: [TextAlertAction(type: .defaultAction, title: self.strings.Common_OK, action: { [weak self] in
            if dismiss {
                self?.dismiss()
            }
        })])
        self.present(alert, in: .window(.root))
    }

    // MARK: - Layout

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout

        let size = layout.size
        let top = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top, 20.0)
        let bottomInset = max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom)
        let sideInset = max(layout.safeInsets.left, layout.safeInsets.right)

        self.titleLabel.frame = CGRect(x: sideInset + 16.0, y: top, width: size.width - sideInset * 2.0 - 32.0, height: 44.0)

        let hasRange = !self.rangeView.isHidden
        let buttonsHeight: CGFloat = 76.0
        let rangeHeight: CGFloat = hasRange ? 48.0 + 22.0 : 0.0
        let hintHeight: CGFloat = 40.0
        let bottomPanelHeight = hintHeight + rangeHeight + buttonsHeight
        var y = size.height - bottomInset - buttonsHeight

        self.cancelButton.frame = CGRect(x: sideInset + 12.0, y: y + 14.0, width: 100.0, height: 48.0)
        self.cancelButton.contentHorizontalAlignment = .left
        self.sendButton.frame = CGRect(x: size.width - sideInset - 16.0 - 56.0, y: y + 10.0, width: 56.0, height: 56.0)

        if hasRange {
            y -= 22.0
            self.rangeLabel.frame = CGRect(x: sideInset + 16.0, y: y, width: size.width - sideInset * 2.0 - 32.0, height: 20.0)
            y -= 48.0
            self.rangeView.frame = CGRect(x: sideInset + 16.0, y: y, width: size.width - sideInset * 2.0 - 32.0, height: 44.0)
        }
        y -= hintHeight
        self.hintLabel.frame = CGRect(x: sideInset + 16.0, y: y, width: size.width - sideInset * 2.0 - 32.0, height: hintHeight)

        let progressPanelFrame = CGRect(x: 0.0, y: size.height - bottomInset - bottomPanelHeight, width: size.width, height: bottomPanelHeight + bottomInset)
        self.progressPanel.frame = progressPanelFrame
        self.progressLabel.frame = CGRect(x: 16.0, y: 16.0, width: size.width - 32.0, height: 24.0)
        self.progressCancelButton.frame = CGRect(x: floor((size.width - 140.0) / 2.0), y: 56.0, width: 140.0, height: 44.0)

        let containerFrame = CGRect(x: 0.0, y: top + 44.0, width: size.width, height: max(1.0, y - top - 44.0))
        self.videoContainer.frame = containerFrame
        self.activityIndicator.center = CGPoint(x: containerFrame.midX, y: containerFrame.midY)

        self.circleDiameter = max(1.0, min(containerFrame.width, containerFrame.height) - 32.0)
        self.circleCenter = CGPoint(x: containerFrame.width / 2.0, y: containerFrame.height / 2.0)

        let circleRect = CGRect(x: self.circleCenter.x - self.circleDiameter / 2.0, y: self.circleCenter.y - self.circleDiameter / 2.0, width: self.circleDiameter, height: self.circleDiameter)
        let overlayPath = UIBezierPath(rect: CGRect(origin: .zero, size: containerFrame.size))
        overlayPath.append(UIBezierPath(ovalIn: circleRect))
        self.overlayLayer.frame = CGRect(origin: .zero, size: containerFrame.size)
        self.overlayLayer.path = overlayPath.cgPath
        self.ringLayer.frame = self.overlayLayer.frame
        self.ringLayer.path = UIBezierPath(ovalIn: circleRect).cgPath
        self.progressLayer.frame = self.overlayLayer.frame
        let ringRect = circleRect.insetBy(dx: -6.0, dy: -6.0)
        self.progressLayer.path = UIBezierPath(arcCenter: CGPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2.0, startAngle: -CGFloat.pi / 2.0, endAngle: CGFloat.pi * 1.5, clockwise: true).cgPath

        if self.displaySize.width > 0.0 && self.displaySize.height > 0.0 {
            self.baseScale = CGFloat(LuckgramRoundVideoGeometry.baseScale(circleDiameter: Double(self.circleDiameter), width: Double(self.displaySize.width), height: Double(self.displaySize.height)))
            self.applyTransform()
        }
    }

    private func applyTransform() {
        guard self.displaySize.width > 0.0 else {
            return
        }
        let baseWidth = self.displaySize.width * self.baseScale
        let baseHeight = self.displaySize.height * self.baseScale
        let clamped = LuckgramRoundVideoGeometry.clampOffset(width: Double(self.displaySize.width), height: Double(self.displaySize.height), baseScale: Double(self.baseScale), zoom: Double(self.zoom), circleDiameter: Double(self.circleDiameter), x: Double(self.offset.x), y: Double(self.offset.y))
        self.offset = CGPoint(x: clamped.x, y: clamped.y)

        self.playerView.transform = .identity
        self.playerView.bounds = CGRect(x: 0.0, y: 0.0, width: baseWidth, height: baseHeight)
        self.playerView.center = CGPoint(x: self.circleCenter.x + self.offset.x, y: self.circleCenter.y + self.offset.y)
        self.playerView.transform = CGAffineTransform(scaleX: self.zoom, y: self.zoom)
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard self.exporter == nil else {
            return
        }
        let translation = gesture.translation(in: self.videoContainer)
        gesture.setTranslation(.zero, in: self.videoContainer)
        self.offset.x += translation.x
        self.offset.y += translation.y
        self.applyTransform()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard self.exporter == nil else {
            return
        }
        switch gesture.state {
        case .began:
            self.pinchStartZoom = self.zoom
        case .changed:
            let newZoom = CGFloat(LuckgramRoundVideoGeometry.clampZoom(Double(self.pinchStartZoom * gesture.scale)))
            let ratio = newZoom / self.zoom
            self.offset = CGPoint(x: self.offset.x * ratio, y: self.offset.y * ratio)
            self.zoom = newZoom
            self.applyTransform()
        default:
            break
        }
    }

    // MARK: - Actions

    @objc private func cancelPressed() {
        if self.exporter != nil {
            self.cancelConversion()
        } else {
            self.player?.pause()
            self.dismiss()
        }
    }

    @objc private func cancelConversion() {
        guard let exporter = self.exporter else {
            return
        }
        // The exporter stops and removes its partial file; nothing is sent.
        exporter.cancel()
        self.exporter = nil
        self.setConverting(false)
        self.player?.play()
    }

    private func setConverting(_ converting: Bool) {
        self.progressPanel.isHidden = !converting
        self.progressLayer.isHidden = !converting
        self.progressLayer.strokeEnd = 0.0
        self.sendButton.isEnabled = !converting
        self.rangeView.isUserInteractionEnabled = !converting
        self.updateProgress(0.0)
    }

    private func updateProgress(_ value: Float) {
        self.progressLabel.text = String(format: self.string(.converting), Int(value * 100.0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.progressLayer.strokeEnd = CGFloat(max(0.01, value))
        CATransaction.commit()
    }

    @objc private func sendPressed() {
        guard self.exporter == nil, !self.didSend, let asset = self.avAsset, let videoTrack = self.videoTrack else {
            return
        }
        let scale = self.baseScale * self.zoom
        guard scale > 0.0 else {
            return
        }
        let crop = LuckgramRoundVideoGeometry.cropSquare(width: Double(self.displaySize.width), height: Double(self.displaySize.height), baseScale: Double(self.baseScale), zoom: Double(self.zoom), circleDiameter: Double(self.circleDiameter), offsetX: Double(self.offset.x), offsetY: Double(self.offset.y))
        let cropRect = CGRect(x: crop.x, y: crop.y, width: crop.side, height: crop.side)

        let range = LuckgramRoundVideoGeometry.exportRange(start: self.rangeStart, end: self.rangeEnd)
        let start = range.start
        let end = range.end
        let timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))

        self.player?.pause()
        let exporter = LuckgramRoundVideoExporter(asset: asset, videoTrack: videoTrack, audioTrack: self.audioTrack, cropRect: cropRect, timeRange: timeRange)
        self.exporter = exporter
        self.setConverting(true)

        exporter.start(progress: { [weak self, weak exporter] value in
            guard let self, let exporter, self.exporter === exporter else {
                return
            }
            self.updateProgress(value)
        }, completion: { [weak self, weak exporter] result in
            guard let self, let exporter, self.exporter === exporter else {
                if case let .completed(url) = result {
                    try? FileManager.default.removeItem(at: url)
                }
                return
            }
            self.exporter = nil
            switch result {
            case let .completed(url):
                self.finish(url: url, side: exporter.outputSide, duration: end - start)
            case .failed:
                self.setConverting(false)
                self.player?.play()
                self.showFailure(dismiss: false)
            case .cancelled:
                self.setConverting(false)
                self.player?.play()
            }
        })
    }

    private func finish(url: URL, side: Int, duration: Double) {
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            self.setConverting(false)
            self.showFailure(dismiss: false)
            return
        }
        self.didSend = true

        let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
        self.context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data, synchronous: true)

        var previewRepresentations: [TelegramMediaImageRepresentation] = []
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320.0, height: 320.0)
        if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil), let thumbnailData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.6) {
            let thumbnailResource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
            self.context.engine.resources.storeResourceData(id: EngineMediaResource.Id(thumbnailResource.id), data: thumbnailData)
            previewRepresentations.append(TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: Int32(cgImage.width), height: Int32(cgImage.height)), resource: thumbnailResource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false))
        }

        let dimensions = PixelDimensions(width: Int32(side), height: Int32(side))
        let media = TelegramMediaFile(
            fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)),
            partialReference: nil,
            resource: resource,
            previewRepresentations: previewRepresentations,
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "video/mp4",
            size: Int64(data.count),
            attributes: [
                .FileName(fileName: "video.mp4"),
                .Video(duration: duration, size: dimensions, flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)
            ],
            alternativeRepresentations: []
        )
        let message: EnqueueMessage = .message(
            text: "",
            attributes: [],
            inlineStickers: [:],
            mediaReference: .standalone(media: media),
            threadId: nil,
            replyToMessageId: nil,
            replyToStoryId: nil,
            localGroupingKey: nil,
            correlationId: nil,
            bubbleUpEmojiOrStickersets: []
        )
        self.player?.pause()
        self.completion(message)
        self.dismiss()
    }
}

private final class LuckgramSimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

private final class LuckgramPlayerView: UIView {
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        return self.layer as! AVPlayerLayer
    }
}

private func generateSendArrow() -> UIImage? {
    let size = CGSize(width: 24.0, height: 24.0)
    UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
    defer {
        UIGraphicsEndImageContext()
    }
    guard let context = UIGraphicsGetCurrentContext() else {
        return nil
    }
    context.setStrokeColor(UIColor.white.cgColor)
    context.setLineWidth(2.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 12.0, y: 20.0))
    context.addLine(to: CGPoint(x: 12.0, y: 4.5))
    context.move(to: CGPoint(x: 5.5, y: 11.0))
    context.addLine(to: CGPoint(x: 12.0, y: 4.5))
    context.addLine(to: CGPoint(x: 18.5, y: 11.0))
    context.strokePath()
    return UIGraphicsGetImageFromCurrentImageContext()
}

/// Range selector with a filmstrip; the selected window is at most `maxLength` seconds.
final class LuckgramRangeView: UIView {
    var rangeChanged: ((Double, Double, Bool) -> Void)?
    var rangeChangeEnded: (() -> Void)?
    private(set) var isTracking = false

    private let stripView = UIView()
    private let leftDim = UIView()
    private let rightDim = UIView()
    private let windowView = UIView()
    private let leftHandle = UIView()
    private let rightHandle = UIView()
    private let positionView = UIView()

    private var duration: Double = 1.0
    private var maxLength: Double = 60.0
    private var minLength: Double = 1.0
    private var start: Double = 0.0
    private var end: Double = 60.0
    private var position: Double = 0.0
    private var imageViews: [UIImageView] = []
    private var generator: AVAssetImageGenerator?

    private enum DragMode {
        case left
        case right
        case window
    }
    private var dragMode: DragMode?
    private var dragStartX: CGFloat = 0.0
    private var dragStartRange: (Double, Double) = (0.0, 0.0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.stripView.clipsToBounds = true
        self.stripView.layer.cornerRadius = 6.0
        self.stripView.backgroundColor = UIColor(white: 0.2, alpha: 1.0)
        self.addSubview(self.stripView)
        self.leftDim.backgroundColor = UIColor(white: 0.0, alpha: 0.6)
        self.rightDim.backgroundColor = UIColor(white: 0.0, alpha: 0.6)
        self.addSubview(self.leftDim)
        self.addSubview(self.rightDim)
        self.windowView.layer.borderColor = UIColor.white.cgColor
        self.windowView.layer.borderWidth = 2.0
        self.windowView.layer.cornerRadius = 6.0
        self.windowView.isUserInteractionEnabled = false
        self.addSubview(self.windowView)
        for handle in [self.leftHandle, self.rightHandle] {
            handle.backgroundColor = .white
            handle.layer.cornerRadius = 3.0
            handle.isUserInteractionEnabled = false
            self.addSubview(handle)
        }
        self.positionView.backgroundColor = .white
        self.positionView.layer.cornerRadius = 1.0
        self.positionView.isUserInteractionEnabled = false
        self.addSubview(self.positionView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        self.addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(asset: AVAsset, duration: Double, maxLength: Double) {
        self.duration = max(0.001, duration)
        self.maxLength = maxLength
        self.minLength = min(1.0, duration)
        self.start = 0.0
        self.end = min(duration, maxLength)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120.0, height: 120.0)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        self.generator = generator

        let count = 10
        var times: [NSValue] = []
        for i in 0 ..< count {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            self.stripView.addSubview(imageView)
            self.imageViews.append(imageView)
            times.append(NSValue(time: CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)))
        }
        generator.generateCGImagesAsynchronously(forTimes: times, completionHandler: { [weak self] requestedTime, image, _, _, _ in
            guard let image else {
                return
            }
            let uiImage = UIImage(cgImage: image)
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let index = times.firstIndex(where: { CMTimeCompare($0.timeValue, requestedTime) == 0 }), index < self.imageViews.count {
                    self.imageViews[index].image = uiImage
                }
            }
        })
        self.setNeedsLayout()
    }

    deinit {
        self.generator?.cancelAllCGImageGeneration()
    }

    func setPlaybackPosition(_ value: Double) {
        self.position = value
        self.layoutPosition()
    }

    private func x(for time: Double) -> CGFloat {
        return self.bounds.width * CGFloat(time / self.duration)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.stripView.frame = CGRect(origin: .zero, size: size)
        if !self.imageViews.isEmpty {
            let width = size.width / CGFloat(self.imageViews.count)
            for (i, imageView) in self.imageViews.enumerated() {
                imageView.frame = CGRect(x: CGFloat(i) * width, y: 0.0, width: ceil(width), height: size.height)
            }
        }
        let startX = self.x(for: self.start)
        let endX = self.x(for: self.end)
        self.leftDim.frame = CGRect(x: 0.0, y: 0.0, width: max(0.0, startX), height: size.height)
        self.rightDim.frame = CGRect(x: endX, y: 0.0, width: max(0.0, size.width - endX), height: size.height)
        self.windowView.frame = CGRect(x: startX, y: 0.0, width: max(4.0, endX - startX), height: size.height)
        self.leftHandle.frame = CGRect(x: startX - 3.0, y: 6.0, width: 6.0, height: size.height - 12.0)
        self.rightHandle.frame = CGRect(x: endX - 3.0, y: 6.0, width: 6.0, height: size.height - 12.0)
        self.layoutPosition()
    }

    private func layoutPosition() {
        let x = self.x(for: max(self.start, min(self.end, self.position)))
        self.positionView.frame = CGRect(x: x - 1.0, y: 2.0, width: 2.0, height: self.bounds.height - 4.0)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let startX = self.x(for: self.start)
            let endX = self.x(for: self.end)
            if abs(location.x - startX) < 24.0 && abs(location.x - startX) <= abs(location.x - endX) {
                self.dragMode = .left
            } else if abs(location.x - endX) < 24.0 {
                self.dragMode = .right
            } else {
                self.dragMode = .window
            }
            self.dragStartX = location.x
            self.dragStartRange = (self.start, self.end)
            self.isTracking = true
        case .changed:
            guard let dragMode = self.dragMode, self.bounds.width > 0.0 else {
                return
            }
            let delta = Double((location.x - self.dragStartX) / self.bounds.width) * self.duration
            let mode: LuckgramRoundVideoGeometry.DragMode
            switch dragMode {
            case .left:
                mode = .left
            case .right:
                mode = .right
            case .window:
                mode = .window
            }
            let (start, end) = LuckgramRoundVideoGeometry.dragRange(mode: mode, start: self.dragStartRange.0, end: self.dragStartRange.1, delta: delta, duration: self.duration, minLength: self.minLength)
            self.start = start
            self.end = end
            self.setNeedsLayout()
            self.rangeChanged?(start, end, dragMode == .right)
        default:
            self.dragMode = nil
            self.isTracking = false
            self.rangeChangeEnded?()
        }
    }
}
