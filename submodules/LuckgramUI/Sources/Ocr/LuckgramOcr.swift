import Foundation
import UIKit
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

/// specs#106: recognizes the text in an image, on the device first (Vision). Also used by
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
        return .fail(LuckgramOcrError(code: LuckgramOcrError.notImplemented)) // implementation: feat/106-image-ocr
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
