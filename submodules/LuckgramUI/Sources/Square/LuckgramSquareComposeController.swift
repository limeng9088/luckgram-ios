import Foundation
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI
import LuckgramDiscover

// New post (spec 26 item 4): text up to 1000 characters plus either up to 9 photos or one short
// video, picked with the system photo picker (PHPicker: no photo-library permission) or taken
// with the camera. Photos are redrawn at ≤ 2048 px and re-encoded as JPEG, videos are exported
// with AVAssetExportSession to H.264/AAC MP4 at ≤ 1280 px with metadata filtered out and trimmed
// to the limit with the user's consent, plus the first frame as cover. Everything goes up through
// presigned URLs, then the post is created and is public at once. Same flow as
// SquareComposeActivity on Android.

private final class SquareComposeArguments {
    let updateText: (String) -> Void
    let addAttachment: () -> Void
    let removeImage: (Int) -> Void
    let removeVideo: () -> Void
    let clearImages: () -> Void

    init(updateText: @escaping (String) -> Void, addAttachment: @escaping () -> Void, removeImage: @escaping (Int) -> Void, removeVideo: @escaping () -> Void, clearImages: @escaping () -> Void) {
        self.updateText = updateText
        self.addAttachment = addAttachment
        self.removeImage = removeImage
        self.removeVideo = removeVideo
        self.clearImages = clearImages
    }
}

private enum SquareComposeEntry: ItemListNodeEntry {
    case text(String, String)
    case image(Int, String, UIImage?)
    case video(String, UIImage?)
    case add(String, Bool)
    case clear(String, Bool)
    case progress(String)
    case info(String)

    var section: ItemListSectionId {
        switch self {
        case .text:
            return 0
        case .image, .video, .add, .clear, .progress, .info:
            return 1
        }
    }

    var stableId: Int {
        switch self {
        case .text: return 0
        case let .image(i, _, _): return 10 + i
        case .video: return 50
        case .add: return 100
        case .clear: return 101
        case .progress: return 102
        case .info: return 103
        }
    }

    static func == (lhs: SquareComposeEntry, rhs: SquareComposeEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.text(a1, a2), .text(b1, b2)): return a1 == b1 && a2 == b2
        case let (.image(a1, a2, a3), .image(b1, b2, b3)): return a1 == b1 && a2 == b2 && a3 === b3
        case let (.video(a1, a2), .video(b1, b2)): return a1 == b1 && a2 === b2
        case let (.add(a1, a2), .add(b1, b2)): return a1 == b1 && a2 == b2
        case let (.clear(a1, a2), .clear(b1, b2)): return a1 == b1 && a2 == b2
        case let (.progress(a), .progress(b)): return a == b
        case let (.info(a), .info(b)): return a == b
        default: return false
        }
    }

    static func < (lhs: SquareComposeEntry, rhs: SquareComposeEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SquareComposeArguments
        switch self {
        case let .text(text, placeholder):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: placeholder, maxLength: ItemListMultilineInputItemTextLimit(value: SquareLogic.textMax, display: true), sectionId: self.section, style: .blocks, minimalHeight: 120.0, textUpdated: { value in
                arguments.updateText(value)
            })
        case let .image(index, title, thumbnail):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: thumbnail, title: title, label: "✕", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.removeImage(index)
            })
        case let .video(title, thumbnail):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: thumbnail, title: title, label: "✕", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.removeVideo()
            })
        case let .add(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.addAttachment()
            })
        case let .clear(title, isVideo):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                if isVideo {
                    arguments.removeVideo()
                } else {
                    arguments.clearImages()
                }
            })
        case let .progress(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {})
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// A photo ready to upload: JPEG bytes without metadata and a small thumbnail for the list.
struct LuckgramSquarePreparedImage {
    let jpeg: Data
    let width: Int
    let height: Int
    let thumbnail: UIImage?
}

/// A video ready to upload: the exported MP4, its cover frame and a thumbnail for the list.
struct LuckgramSquarePreparedVideo {
    let fileUrl: URL
    let coverJpeg: Data
    let thumbnail: UIImage?
    let width: Int
    let height: Int
    let durationSeconds: Int

    func delete() {
        try? FileManager.default.removeItem(at: self.fileUrl)
    }
}

enum LuckgramSquareImages {
    static let jpegQuality: CGFloat = 0.85

    static func thumbnail(of image: UIImage, side: CGFloat = 40.0) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let k = max(size.width / max(1, image.size.width), size.height / max(1, image.size.height))
            let drawSize = CGSize(width: image.size.width * k, height: image.size.height * k)
            image.draw(in: CGRect(x: (size.width - drawSize.width) / 2.0, y: (size.height - drawSize.height) / 2.0, width: drawSize.width, height: drawSize.height))
        }
    }

    /// Redraws `image` at ≤ 2048 px (long edge) and encodes it as JPEG. Drawing into a new
    /// bitmap drops every property of the original (orientation is applied, EXIF is gone).
    static func prepare(_ image: UIImage) -> LuckgramSquarePreparedImage? {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        let size = SquareLogic.scaledSize(width: pixelWidth, height: pixelHeight)
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let target = CGSize(width: size.width, height: size.height)
        let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = redrawn.jpegData(compressionQuality: jpegQuality) else {
            return nil
        }
        return LuckgramSquarePreparedImage(jpeg: jpeg, width: size.width, height: size.height, thumbnail: thumbnail(of: redrawn))
    }
}

enum LuckgramSquareVideos {
    enum Failure: Error {
        case unreadable
        case tooBig
    }

    /// Duration and display size of a picked video (orientation applied). `seconds` is rounded
    /// down for display (same as the feed badge); `exact` is for the length check.
    static func probe(_ url: URL) -> (seconds: Int, exact: Double, width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        let exact = CMTimeGetSeconds(asset.duration)
        guard exact.isFinite, exact > 0, let track = asset.tracks(withMediaType: .video).first else {
            return nil
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        return (SquareLogic.wholeSeconds(exact), exact, Int(abs(size.width)), Int(abs(size.height)))
    }

    /// Exports `url` to H.264/AAC MP4 at ≤ 1280 px, keeping only the first `keepSeconds`, with
    /// the metadata filtered out (location included); the first frame becomes the cover.
    static func prepare(_ url: URL, keepSeconds: Int, progress: @escaping (Float) -> Void, completion: @escaping (Result<LuckgramSquarePreparedVideo, Failure>) -> Void) -> () -> Void {
        let asset = AVURLAsset(url: url)
        guard let source = probe(url) else {
            completion(.failure(.unreadable))
            return {}
        }
        let size = SquareLogic.videoSize(width: source.width, height: source.height)
        let preset = max(size.width, size.height) > 960 ? AVAssetExportPreset1280x720 : AVAssetExportPreset960x540
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            completion(.failure(.unreadable))
            return {}
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("luckgram_square_\(UInt64(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0 ..< 1_000_000)).mp4")
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.metadata = []
        export.metadataItemFilter = AVMetadataItemFilter.forSharing()
        let keep = CMTime(seconds: Double(keepSeconds), preferredTimescale: 600)
        if CMTimeCompare(asset.duration, keep) > 0 {
            export.timeRange = CMTimeRange(start: .zero, duration: keep)
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            progress(export.progress)
        }
        export.exportAsynchronously {
            timer.invalidate()
            DispatchQueue.main.async {
                guard export.status == .completed, let attrs = try? FileManager.default.attributesOfItem(atPath: output.path), let bytes = attrs[.size] as? NSNumber else {
                    try? FileManager.default.removeItem(at: output)
                    completion(.failure(export.status == .cancelled ? .unreadable : .unreadable))
                    return
                }
                if bytes.intValue > LuckgramSquare.maxVideoMb * 1024 * 1024 {
                    try? FileManager.default.removeItem(at: output)
                    completion(.failure(.tooBig))
                    return
                }
                let exported = AVURLAsset(url: output)
                let generator = AVAssetImageGenerator(asset: exported)
                generator.appliesPreferredTrackTransform = true
                guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                    try? FileManager.default.removeItem(at: output)
                    completion(.failure(.unreadable))
                    return
                }
                let cover = UIImage(cgImage: cg)
                guard let coverJpeg = cover.jpegData(compressionQuality: LuckgramSquareImages.jpegQuality) else {
                    try? FileManager.default.removeItem(at: output)
                    completion(.failure(.unreadable))
                    return
                }
                let finalSize = probe(output) ?? (min(keepSeconds, source.seconds), Double(min(keepSeconds, source.seconds)), size.width, size.height)
                completion(.success(LuckgramSquarePreparedVideo(fileUrl: output, coverJpeg: coverJpeg, thumbnail: LuckgramSquareImages.thumbnail(of: cover), width: finalSize.width, height: finalSize.height, durationSeconds: min(keepSeconds, finalSize.seconds))))
            }
        }
        return {
            export.cancelExport()
        }
    }
}

private final class SquareComposeState {
    var text = ""
    var images: [LuckgramSquarePreparedImage] = []
    var video: LuckgramSquarePreparedVideo?
    var preparing = false
    /// What `preparing` is about: a video (transcode) or photos.
    var preparingVideo = false
    var prepareProgress: Float = -1
    var publishing = false
    var progressText: String?
}

/// PHPicker delegate kept alive by the controller while the picker is up. Delivers photos as
/// images and a video as a copied file URL.
private final class LuckgramSquarePickerDelegate: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let completion: ([UIImage], URL?, Bool) -> Void

    init(completion: @escaping ([UIImage], URL?, Bool) -> Void) {
        self.completion = completion
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        if results.isEmpty {
            self.completion([], nil, false)
            return
        }
        if let movie = results.first(where: { $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }) {
            movie.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                var copied: URL?
                if let url {
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent("luckgram_square_pick_\(UInt64(Date().timeIntervalSince1970 * 1000)).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
                    try? FileManager.default.removeItem(at: target)
                    if (try? FileManager.default.copyItem(at: url, to: target)) != nil {
                        copied = target
                    }
                }
                DispatchQueue.main.async {
                    self.completion([], copied, copied == nil)
                }
            }
            return
        }
        let group = DispatchGroup()
        var images: [UIImage?] = Array(repeating: nil, count: results.count)
        var failed = false
        for (i, result) in results.enumerated() {
            group.enter()
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                if let image = object as? UIImage {
                    images[i] = image
                } else {
                    failed = true
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.completion(images.compactMap { $0 }, nil, failed)
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let url = info[.mediaURL] as? URL {
            self.completion([], url, false)
        } else if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
            self.completion([image], nil, false)
        } else {
            self.completion([], nil, true)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        self.completion([], nil, false)
    }
}

public func luckgramSquareComposeController(context: AccountContext) -> ViewController {
    let tx = LuckgramSquare.texts
    let state = SquareComposeState()
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    func refresh() {
        version += 1
        updated.set(version)
    }

    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?
    var presentNativeImpl: ((UIViewController) -> Void)?
    let present: (ViewController) -> Void = { presentImpl?($0) }
    let push: (ViewController) -> Void = { pushImpl?($0) }
    let requests = DisposableSet()
    var pickerDelegate: LuckgramSquarePickerDelegate?
    var cancelExport: (() -> Void)?

    func fail(_ error: LuckgramAIError) {
        state.publishing = false
        state.progressText = nil
        refresh()
        LuckgramSquare.showError(error, context: context, present: present, push: push)
    }

    func createPost(_ body: [String: Any]) {
        requests.add(LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/square/posts", body: body).start(next: { j in
            state.publishing = false
            let p = SquareLogic.parsePost(j)
            if !p.author.id.isEmpty {
                LuckgramSquare.myAuthorId = p.author.id
            }
            state.video?.delete()
            state.video = nil
            LuckgramSquare.noteNeedsRefresh()
            dismissImpl?()
            LuckgramSquare.toast(context: context, tx.published, present: present)
        }, error: { error in
            fail(error)
        }))
    }

    /// Uploads each payload to its slot, in order, then calls `done` with the keys.
    func uploadAll(_ uploads: [SquareLogic.Upload], payloads: [(Data, String)], done: @escaping ([String]) -> Void) {
        var chain: Signal<[String], LuckgramAIError> = .single([])
        for (i, payload) in payloads.enumerated() {
            let upload = uploads[i]
            chain = chain |> mapToSignal { acc -> Signal<[String], LuckgramAIError> in
                return LuckgramAI.shared.putPresigned(url: upload.url, contentType: payload.1, body: payload.0)
                |> map { _ in acc + [upload.key] }
            }
        }
        var keys: [String] = []
        requests.add((chain |> deliverOnMainQueue).start(next: { all in
            keys = all
        }, error: { error in
            fail(error)
        }, completed: {
            if keys.count == payloads.count {
                done(keys)
            } else {
                fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
            }
        }))
    }

    func requestUploads(contentType: String, sizes: [Int], then: @escaping ([SquareLogic.Upload]) -> Void) {
        requests.add(LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/square/uploads", body: SquareLogic.uploadsBody(contentType: contentType, sizes: sizes)).start(next: { j in
            let uploads = SquareLogic.parseUploads(j)
            if uploads.count < sizes.count {
                fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
                return
            }
            then(uploads)
        }, error: { error in
            fail(error)
        }))
    }

    func publish() {
        if state.publishing || state.preparing {
            return
        }
        if !SquareLogic.isValidPost(text: state.text, images: state.images.count, hasVideo: state.video != nil) {
            LuckgramSquare.toast(context: context, SquareLogic.length(state.text.trimmingCharacters(in: .whitespacesAndNewlines)) > SquareLogic.textMax ? tx.tooLong : tx.needContent, present: present)
            return
        }
        requests.add(LuckgramSquare.requireProfile(context: context, present: present, push: push, then: {
            state.publishing = true
            state.progressText = nil
            refresh()
            if let video = state.video {
                state.progressText = tx.uploadingVideo
                refresh()
                // One slot for the MP4, one for its cover; the server only accepts a video post with both.
                // The MP4 is streamed from disk; only the cover is held in memory.
                let videoBytes = ((try? FileManager.default.attributesOfItem(atPath: video.fileUrl.path))?[.size] as? NSNumber)?.intValue ?? 0
                requestUploads(contentType: SquareLogic.videoContentType, sizes: [videoBytes], then: { videoUploads in
                    requestUploads(contentType: SquareLogic.imageContentType, sizes: [video.coverJpeg.count], then: { coverUploads in
                        requests.add((LuckgramAI.shared.putPresigned(url: videoUploads[0].url, contentType: SquareLogic.videoContentType, fileUrl: video.fileUrl, progress: { fraction in
                            Queue.mainQueue().async {
                                guard state.publishing else {
                                    return
                                }
                                let next = tx.uploadingVideo(max(0, min(100, Int((fraction * 100).rounded(.down)))))
                                if next != state.progressText {
                                    state.progressText = next
                                    refresh()
                                }
                            }
                        })
                        |> deliverOnMainQueue).start(error: { error in
                            fail(error)
                        }, completed: {
                            uploadAll([coverUploads[0]], payloads: [(video.coverJpeg, SquareLogic.imageContentType)], done: { keys in
                                createPost(SquareLogic.postBody(text: state.text, videoKey: videoUploads[0].key, coverKey: keys[0]))
                            })
                        }))
                    })
                })
            } else if state.images.isEmpty {
                createPost(SquareLogic.postBody(text: state.text, imageKeys: []))
            } else {
                requestUploads(contentType: SquareLogic.imageContentType, sizes: state.images.map { $0.jpeg.count }, then: { uploads in
                    uploadAll(uploads, payloads: state.images.map { ($0.jpeg, SquareLogic.imageContentType) }, done: { keys in
                        createPost(SquareLogic.postBody(text: state.text, imageKeys: keys))
                    })
                })
            }
        }))
    }

    func addImages(_ images: [UIImage], failed: Bool) {
        if images.isEmpty {
            if failed {
                LuckgramSquare.toast(context: context, tx.imageFailed, present: present)
            }
            return
        }
        if state.video != nil {
            LuckgramSquare.toast(context: context, tx.onlyOneAttachmentType, present: present)
            return
        }
        state.preparing = true
        state.preparingVideo = false
        state.prepareProgress = -1
        refresh()
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = images.compactMap { LuckgramSquareImages.prepare($0) }
            DispatchQueue.main.async {
                state.preparing = false
                for p in prepared where state.images.count < SquareLogic.imagesMax {
                    state.images.append(p)
                }
                refresh()
                if failed || prepared.count < images.count {
                    LuckgramSquare.toast(context: context, tx.imageFailed, present: present)
                }
            }
        }
    }

    func transcode(_ url: URL, keepSeconds: Int) {
        state.preparing = true
        state.preparingVideo = true
        state.prepareProgress = 0
        refresh()
        cancelExport = LuckgramSquareVideos.prepare(url, keepSeconds: keepSeconds, progress: { p in
            state.prepareProgress = p
            refresh()
        }, completion: { result in
            cancelExport = nil
            try? FileManager.default.removeItem(at: url)
            state.preparing = false
            state.prepareProgress = -1
            switch result {
            case let .success(video):
                state.video?.delete()
                state.video = video
            case let .failure(reason):
                LuckgramSquare.toast(context: context, reason == .tooBig ? tx.videoTooBig(LuckgramSquare.maxVideoMb) : tx.videoFailed, present: present)
            }
            refresh()
        })
    }

    func addVideo(_ url: URL) {
        if !state.images.isEmpty {
            try? FileManager.default.removeItem(at: url)
            LuckgramSquare.toast(context: context, tx.onlyOneAttachmentType, present: present)
            return
        }
        let maxSeconds = LuckgramSquare.maxVideoSeconds
        guard let probe = LuckgramSquareVideos.probe(url) else {
            try? FileManager.default.removeItem(at: url)
            LuckgramSquare.toast(context: context, tx.videoFailed, present: present)
            return
        }
        if probe.exact > Double(maxSeconds) {
            // Spec 26 item 3: too long → let the user trim (keep the first N seconds) or cancel.
            present(textAlertController(context: context, title: tx.videoTooLongTitle, text: tx.videoTooLong(maxSeconds, probe.seconds), actions: [
                TextAlertAction(type: .genericAction, title: tx.cancel, action: {
                    try? FileManager.default.removeItem(at: url)
                }),
                TextAlertAction(type: .defaultAction, title: tx.trimAndContinue(maxSeconds), action: {
                    transcode(url, keepSeconds: maxSeconds)
                })
            ]))
        } else {
            transcode(url, keepSeconds: maxSeconds)
        }
    }

    func showPicker(videos: Bool) {
        var config = PHPickerConfiguration()
        config.filter = videos ? .videos : .images
        config.selectionLimit = videos ? 1 : SquareLogic.imagesMax - state.images.count
        let picker = PHPickerViewController(configuration: config)
        let delegate = LuckgramSquarePickerDelegate(completion: { images, videoUrl, failed in
            pickerDelegate = nil
            if let videoUrl {
                addVideo(videoUrl)
            } else if videos && failed {
                LuckgramSquare.toast(context: context, tx.videoFailed, present: present)
            } else {
                addImages(images, failed: failed)
            }
        })
        pickerDelegate = delegate
        picker.delegate = delegate
        presentNativeImpl?(picker)
    }

    func showCamera(video: Bool) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [video ? UTType.movie.identifier : UTType.image.identifier]
        if video {
            picker.videoMaximumDuration = TimeInterval(LuckgramSquare.maxVideoSeconds)
            picker.videoQuality = .typeHigh
        }
        let delegate = LuckgramSquarePickerDelegate(completion: { images, videoUrl, failed in
            pickerDelegate = nil
            if let videoUrl {
                addVideo(videoUrl)
            } else {
                addImages(images, failed: failed)
            }
        })
        pickerDelegate = delegate
        picker.delegate = delegate
        presentNativeImpl?(picker)
    }

    func chooseAttachment() {
        guard !state.preparing, !state.publishing else {
            return
        }
        var actions: [TextAlertAction] = []
        if state.video == nil && state.images.count < SquareLogic.imagesMax {
            actions.append(TextAlertAction(type: .genericAction, title: tx.chooseImages, action: { showPicker(videos: false) }))
            actions.append(TextAlertAction(type: .genericAction, title: tx.takePhoto, action: { showCamera(video: false) }))
        }
        if state.images.isEmpty && state.video == nil {
            actions.append(TextAlertAction(type: .genericAction, title: tx.chooseVideo, action: { showPicker(videos: true) }))
            actions.append(TextAlertAction(type: .genericAction, title: tx.recordVideo, action: { showCamera(video: true) }))
        }
        actions.append(TextAlertAction(type: .defaultAction, title: tx.cancel, action: {}))
        present(textAlertController(context: context, title: tx.addAttachment, text: "", actions: actions, actionLayout: .vertical))
    }

    let arguments = SquareComposeArguments(updateText: { text in
        state.text = text
    }, addAttachment: {
        chooseAttachment()
    }, removeImage: { index in
        if !state.publishing && !state.preparing && index < state.images.count {
            state.images.remove(at: index)
            refresh()
        }
    }, removeVideo: {
        if !state.publishing && !state.preparing {
            state.video?.delete()
            state.video = nil
            refresh()
        }
    }, clearImages: {
        if !state.publishing && !state.preparing {
            state.images.removeAll()
            refresh()
        }
    })

    let entries = updated.get() |> map { _ -> [SquareComposeEntry] in
        var e: [SquareComposeEntry] = [.text(state.text, tx.textHint)]
        if let video = state.video {
            e.append(.video(tx.videoLabel(video.durationSeconds) + " · \(video.width) × \(video.height)", video.thumbnail))
        }
        for (i, image) in state.images.enumerated() {
            e.append(.image(i, "\(image.width) × \(image.height)", image.thumbnail))
        }
        if state.preparing {
            let p = state.prepareProgress
            e.append(.progress(state.preparingVideo ? (p >= 0 ? tx.preparingVideo + " \(Int((p * 100).rounded()))%" : tx.preparingVideo) : tx.preparingImages))
        } else if state.publishing {
            e.append(.progress(state.progressText ?? tx.publishing))
        } else {
            if state.video == nil && state.images.count < SquareLogic.imagesMax {
                e.append(.add(state.images.isEmpty ? tx.addAttachment : tx.addImages(state.images.count), true))
            }
            if state.video != nil {
                e.append(.clear(tx.removeVideo, true))
            } else if !state.images.isEmpty {
                e.append(.clear(tx.removeImages, false))
            }
        }
        e.append(.info(tx.attachmentsInfo(LuckgramSquare.maxVideoSeconds) + "\n\n" + tx.dailyLimitInfo(LuckgramSquare.maxPostsPerDay)))
        return e
    }

    let signal = combineLatest(context.sharedContext.presentationData, entries)
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightButton = ItemListNavigationButton(content: .text(state.publishing ? tx.publishing : tx.publish), style: .bold, enabled: !state.publishing && !state.preparing, action: {
            publish()
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tx.composeTitle), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    presentNativeImpl = { [weak controller] native in
        if let window = context.sharedContext.mainWindow {
            window.presentNative(native)
        } else {
            controller?.view.window?.rootViewController?.present(native, animated: true)
        }
    }
    controller.didDisappear = { _ in
        if state.publishing {
            return
        }
    }
    requests.add(ActionDisposable {
        cancelExport?()
        if !state.publishing {
            state.video?.delete()
        }
    })
    return controller
}
