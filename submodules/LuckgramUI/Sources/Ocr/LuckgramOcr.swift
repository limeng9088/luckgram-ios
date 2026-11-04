import Foundation
import UIKit
import Vision
import NaturalLanguage
import SwiftSignalKit

public struct LuckgramOcrError: Error, Equatable {
    public static let notImplemented = "not_implemented"
    public static let noImage = "no_image"
    public static let failed = "ocr_failed"

    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// specs#106: recognizes the text in an image on the device (Vision; nothing is uploaded). Also used by
/// specs#108 (image translation), which only calls `recognize` / `hasText` / `cached`. The last 8
/// results are kept by key (the image file's path), so the viewer's "Text" and "Translate" buttons
/// share one recognition per image. Signals deliver on the main queue.
public enum LuckgramOcr {
    public static let featureKey = "image_ocr"
    static let cacheSize = 8

    private static let lock = NSLock()
    private static var cache: [(key: String, result: LuckgramOcrResult)] = []

    /// The cached result for `key`, or nil.
    public static func cached(key: String?) -> LuckgramOcrResult? {
        guard let key else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return cache.first(where: { $0.key == key })?.result
    }

    static func store(key: String?, result: LuckgramOcrResult) {
        guard let key else {
            return
        }
        lock.lock()
        cache.removeAll(where: { $0.key == key })
        cache.append((key, result))
        if cache.count > cacheSize {
            cache.removeFirst(cache.count - cacheSize)
        }
        lock.unlock()
    }

    /// Recognizes `image`; `key` (e.g. the file path) caches the result, nil = not cached.
    public static func recognize(image: UIImage?, key: String?) -> Signal<LuckgramOcrResult, LuckgramOcrError> {
        guard image != nil else {
            return .fail(LuckgramOcrError(code: LuckgramOcrError.noImage))
        }
        if let hit = cached(key: key) {
            return .single(hit)
        }
        guard let image, let cgImage = image.cgImage else {
            return .fail(LuckgramOcrError(code: LuckgramOcrError.noImage))
        }
        let orientation = cgOrientation(image.imageOrientation)
        let upright = orientation.rawValue >= 5 // left / right: width and height swap
        let width = upright ? cgImage.height : cgImage.width
        let height = upright ? cgImage.width : cgImage.height
        let signal = Signal<LuckgramOcrResult, LuckgramOcrError> { subscriber in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    subscriber.putError(LuckgramOcrError(code: LuckgramOcrError.failed))
                    return
                }
                let result = makeResult(observations, width: width, height: height)
                store(key: key, result: result)
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(iOS 16.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]
            } else {
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            }
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async {
                do {
                    try VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([request])
                } catch {
                    subscriber.putError(LuckgramOcrError(code: LuckgramOcrError.failed))
                }
            }
            return EmptyDisposable
        }
        return signal |> deliverOnMainQueue
    }

    /// Whether "Recognize with Luckgram AI" can be offered (remote config; the server endpoint is new).
    public static var aiAvailable: Bool {
        return LuckgramSettings.shared.remoteConfig.bool(LuckgramOcrResult.aiConfigKey, default: false)
    }

    /// specs#106 需求 2: recognizes with Luckgram AI (the server's vision model): a JPEG of at most
    /// 2048 px is sent; counts against the AI quota. The caller asks the AI consent first. The result
    /// replaces the cached on-device one. Errors are `LuckgramAIError` codes.
    public static func recognizeWithAI(image: UIImage, key: String?, langHint: String?) -> Signal<LuckgramOcrResult, LuckgramAIError> {
        guard let jpeg = aiJpeg(image) else {
            return .fail(LuckgramAIError(code: LuckgramOcrError.noImage))
        }
        let width = Int(image.size.width * image.scale), height = Int(image.size.height * image.scale)
        return LuckgramAI.shared.requestJSON(method: "POST", path: LuckgramOcrResult.aiPath, body: LuckgramOcrResult.aiBody(base64Jpeg: jpeg.base64EncodedString(), langHint: langHint))
        |> map { json -> LuckgramOcrResult in
            let result = LuckgramOcrResult.parseAI(json, imageWidth: width, imageHeight: height)
            store(key: key, result: result)
            return result
        }
        |> deliverOnMainQueue
    }

    private static func aiJpeg(_ image: UIImage) -> Data? {
        let side = CGFloat(LuckgramOcrResult.aiMaxSide)
        let scale = min(1.0, side / max(1.0, max(image.size.width, image.size.height)))
        let size = CGSize(width: max(1.0, floor(image.size.width * scale)), height: max(1.0, floor(image.size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.85, 0.65, 0.45] as [CGFloat] {
            if let data = resized.jpegData(compressionQuality: quality), data.count <= LuckgramOcrResult.aiMaxBytes {
                return data
            }
        }
        return nil
    }

    /// Whether the switch `image_ocr` is on (default on).
    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(featureKey)
    }

    static func makeResult(_ observations: [VNRecognizedTextObservation], width: Int, height: Int) -> LuckgramOcrResult {
        var lines: [LuckgramOcrResult.Line] = []
        for o in observations {
            guard let candidate = o.topCandidates(1).first, !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            let b = o.boundingBox
            let box = LuckgramOcrResult.Box.fromBottomLeft(x: Double(b.minX), y: Double(b.minY), width: Double(b.width), height: Double(b.height))
            let quad = LuckgramOcrResult.Quad(points: [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { (x: Double($0.x), y: 1.0 - Double($0.y)) })
            lines.append(LuckgramOcrResult.Line(text: candidate.string, box: box, quad: quad))
        }
        let blocks = LuckgramOcrResult.paragraphs(lines).map { group -> LuckgramOcrResult.Block in
            let text = group.map { $0.text }.joined(separator: "\n")
            return LuckgramOcrResult.Block.of(lines: group, language: language(of: text))
        }
        let ordered = LuckgramOcrResult.readingOrder(blocks)
        return LuckgramOcrResult(imageWidth: width, imageHeight: height, language: LuckgramOcrResult.mainLanguage(ordered), source: .device, blocks: ordered)
    }

    /// From the script for CJK, else the system language recognizer (on the device).
    static func language(of text: String) -> String? {
        if let s = LuckgramOcrResult.scriptLanguage(text) {
            return s
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage, lang != .undetermined else {
            return nil
        }
        return lang.rawValue
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// Whether the image has text; shares the recognition (and cache) with `recognize`.
    public static func hasText(image: UIImage?, key: String?) -> Signal<Bool, NoError> {
        return recognize(image: image, key: key)
        |> map { $0.hasText }
        |> `catch` { _ -> Signal<Bool, NoError> in
            return .single(false)
        }
    }
}
