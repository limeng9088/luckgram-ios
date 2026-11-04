import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext

/// specs#108 strings; same texts as Android `ImageTranslateSettings`.
public enum LuckgramImageTranslateStrings {
    public static var translateImage: String { LuckgramStrings.pick("翻译图片", "Translate image") }
    public static var button: String { LuckgramStrings.pick("译", "Tr") }
    public static var original: String { LuckgramStrings.pick("原图", "Original") }
    public static var translated: String { LuckgramStrings.pick("译文", "Translation") }
    public static var copy: String { LuckgramStrings.pick("复制译文", "Copy translation") }
    public static var save: String { LuckgramStrings.pick("保存图片", "Save image") }
    public static var share: String { LuckgramStrings.pick("分享", "Share") }
    public static var sendTranslated: String { LuckgramStrings.pick("发送翻译后的图片", "Send translated image") }
    public static var translating: String { LuckgramStrings.pick("正在翻译…", "Translating…") }
    public static var noText: String { LuckgramStrings.pick("图片里没有识别到要翻译的文字", "No text to translate was found in this image") }
    public static var copied: String { LuckgramStrings.pick("译文已复制", "Translation copied") }
    public static var saved: String { LuckgramStrings.pick("已保存到相册", "Saved to gallery") }
    public static var onlyThisChat: String { LuckgramStrings.pick("仅本聊天", "Only this chat") }
    public static var asDefault: String { LuckgramStrings.pick("设为默认", "Set as default") }
    public static func applyTo(_ lang: String) -> String { LuckgramStrings.pick("图片翻译成\(lang)：", "Translate images to \(lang):") }
    public static var originalLabel: String { LuckgramStrings.pick("原文", "Original") }
    public static var translationLabel: String { LuckgramStrings.pick("译文", "Translation") }
    public static var settingsLanguage: String { LuckgramStrings.pick("图片翻译语言", "Translate images to") }
    public static var followReading: String { LuckgramStrings.pick("跟随阅读翻译语言", "Same as message translation") }
    public static var settingsInfo: String { LuckgramStrings.pick("图片里的文字在本机识别，只把识别出的文字发去翻译，不上传图片。", "Text is recognized on this device; only the recognized text is sent for translation, never the image.") }
}

/// specs#108 需求 2: which language images are translated to. This chat's choice, else the
/// image-only default, else the reading translation language (#105), else the app language.
public enum LuckgramImageTranslateSettings {
    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramImageTranslateLogic.featureKey)
    }

    private static func chatKey(_ peerId: Int64) -> String {
        return LuckgramImageTranslateLogic.chatKeyPrefix + "\(peerId)"
    }

    /// `peerId` nil = not in a chat.
    public static func targetLanguage(peerId: Int64?) -> String {
        let perChat = peerId.flatMap { LuckgramSettings.shared.string(chatKey($0), default: nil) }
        let app = LuckgramStrings.appLanguageCode ?? Locale.current.languageCode
        return LuckgramImageTranslateLogic.targetLanguage(perChat: perChat, imageDefault: imageDefault, readingTarget: LuckgramTranslateInController.targetLanguage, appLanguage: app)
    }

    /// The image-only default, or nil when images follow the reading translation language.
    public static var imageDefault: String? {
        let value = LuckgramSettings.shared.string(LuckgramImageTranslateLogic.toLangKey, default: nil)
        return value?.isEmpty == false ? value : nil
    }

    /// Whether the user picked a language for images yet (first use asks, needs 2).
    public static func hasChosen(peerId: Int64?) -> Bool {
        if imageDefault != nil {
            return true
        }
        return peerId.flatMap { LuckgramSettings.shared.string(chatKey($0), default: nil) }?.isEmpty == false
    }

    /// "Only this chat" (with a peer) or "as default". Choosing the default clears this chat's override.
    public static func setLanguage(peerId: Int64?, lang: String, onlyThisChat: Bool) {
        if onlyThisChat, let peerId {
            LuckgramSettings.shared.setString(chatKey(peerId), lang)
        } else {
            LuckgramSettings.shared.setString(LuckgramImageTranslateLogic.toLangKey, lang)
            if let peerId {
                LuckgramSettings.shared.setString(chatKey(peerId), nil)
            }
        }
    }

    public static func followReadingLanguage() {
        LuckgramSettings.shared.setString(LuckgramImageTranslateLogic.toLangKey, nil)
    }

    public static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else {
            return nil
        }
        let base = LuckgramImageTranslateLogic.base(code)
        let locale = Locale(identifier: LuckgramStrings.isChinese ? "zh-Hans" : "en")
        return locale.localizedString(forLanguageCode: base) ?? base
    }

    /// The language list of spec 01 (set by TelegramUI on the reading-translation controller).
    public static func pickLanguage(selected: String?, completion: @escaping (String) -> Void) -> Bool {
        guard let pick = (luckgramTranslateIn as? LuckgramTranslateInController)?.pickLanguage else {
            return false
        }
        pick(LuckgramImageTranslateLogic.base(selected), [], completion) // specs#105 added the recent list
        return true
    }
}

/// specs#108: translates the recognized text blocks of one image (needs 5: only the text is sent,
/// never the image). Spec 01's channel: cache → Telegram `messages.translateText` (batched, 8 s)
/// → Luckgram AI per block.
public enum LuckgramImageTranslator {
    static let source = "image"

    /// One entry per input (nil = left as is). Fails only when nothing could be translated.
    public static func translate(context: AccountContext, texts: [String?], toLang: String) -> Signal<([String?], String?), LuckgramTranslationFallbackError> {
        let cacheLang = LuckgramTranslateFallbackLogic.aiLanguage(toLang) ?? toLang
        var out = [String?](repeating: nil, count: texts.count)
        var todo: [Int] = []
        var fromLang: String?
        for (i, text) in texts.enumerated() {
            guard let text, !text.isEmpty else {
                continue
            }
            if let hit = LuckgramTranslateService.cached(toLang: cacheLang, text: text) {
                out[i] = hit.text
                fromLang = fromLang ?? hit.fromLang
            } else {
                todo.append(i)
            }
        }
        if todo.isEmpty {
            return .single((out, fromLang))
        }
        let todoTexts = todo.map { texts[$0]! }
        let batches = LuckgramImageTranslateLogic.batches(todoTexts)
        let signals = batches.map { batch -> Signal<([Int], [String?], LuckgramTranslationFallbackError?), NoError> in
            let pieces = batch.map { todoTexts[$0] }
            return translateBatch(context: context, pieces: pieces, toLang: toLang, cacheLang: cacheLang)
            |> map { results, error in (batch, results, error) }
        }
        let cachedFrom = fromLang
        return combineLatest(signals)
        |> castError(LuckgramTranslationFallbackError.self)
        |> mapToSignal { results -> Signal<([String?], String?), LuckgramTranslationFallbackError> in
            var out = out
            var lastError: LuckgramTranslationFallbackError?
            for (batch, translations, error) in results {
                for (j, k) in batch.enumerated() where j < translations.count {
                    if let t = translations[j] {
                        out[todo[k]] = t
                    }
                }
                lastError = error ?? lastError
            }
            if out.allSatisfy({ $0 == nil }), let lastError {
                return .fail(lastError)
            }
            return .single((out, cachedFrom))
        }
        |> deliverOnMainQueue
    }

    private static func translateBatch(context: AccountContext, pieces: [String], toLang: String, cacheLang: String) -> Signal<([String?], LuckgramTranslationFallbackError?), NoError> {
        let telegram: Signal<[String?]?, NoError> = context.engine.messages.translate(texts: pieces.map { ($0, []) }, toLang: toLang)
        |> map { results -> [String?]? in
            guard results.count == pieces.count else {
                return []
            }
            return results.map { $0.0.isEmpty ? nil : $0.0 }
        }
        |> `catch` { _ -> Signal<[String?]?, NoError> in
            // The Telegram error itself is logged by TelegramCore.
            return .single([])
        }
        |> timeout(LuckgramTranslateFallbackLogic.telegramTimeoutSeconds, queue: Queue.mainQueue(), alternate: .single(nil))

        return telegram
        |> deliverOnMainQueue
        |> mapToSignal { results -> Signal<([String?], LuckgramTranslationFallbackError?), NoError> in
            if let results, !results.isEmpty {
                for (i, t) in results.enumerated() {
                    if let t {
                        LuckgramTranslateService.remember(toLang: cacheLang, text: pieces[i], translated: t, fromLang: nil)
                    }
                }
                return .single((results, nil))
            }
            if results == nil {
                luckgramTranslationFallback?.logTelegramFailure(source: source, code: 0, text: LuckgramTranslateFallbackLogic.timeout)
            }
            return viaAi(pieces: pieces, toLang: toLang)
        }
    }

    /// Luckgram AI, one block after another (one consent dialog, low load); stops asking after
    /// consent was declined or the quota is used up.
    private static func viaAi(pieces: [String], toLang: String) -> Signal<([String?], LuckgramTranslationFallbackError?), NoError> {
        guard let fallback = luckgramTranslationFallback else {
            return .single(([String?](repeating: nil, count: pieces.count), LuckgramTranslationFallbackError(code: LuckgramAIError.upstreamUnavailable)))
        }
        return Signal { subscriber in
            var results: [String?] = []
            var lastError: LuckgramTranslationFallbackError?
            let disposable = MetaDisposable()
            func next() {
                if results.count >= pieces.count {
                    subscriber.putNext((results, lastError))
                    subscriber.putCompletion()
                    return
                }
                if let code = lastError?.code, code == "consent_denied" || code == "quota_exceeded" {
                    results.append(nil)
                    next()
                    return
                }
                disposable.set((fallback.translate(source: source, text: pieces[results.count], toLang: toLang) |> deliverOnMainQueue).start(next: { text in
                    results.append(text)
                    next()
                }, error: { error in
                    lastError = error
                    results.append(nil)
                    next()
                }))
            }
            Queue.mainQueue().async {
                next()
            }
            return disposable
        }
    }

    public static func failureMessage(_ error: LuckgramTranslationFallbackError) -> String {
        return luckgramTranslationFallback?.failureMessage(error) ?? LuckgramStrings.pick("翻译失败", "Translation failed")
    }
}

/// specs#108 需求 3: draws the translations over the original image — a semi-transparent cover in
/// the sampled background color on each block, the translation inside it, sized to fit. The result
/// is used for display, save and share alike.
public enum LuckgramImageTranslateRenderer {
    /// One recognized block with its translation (nil = keep the original).
    public struct Block {
        /// Normalized box: x, y, width, height (0..1, origin top-left).
        public let box: [Double]
        public let lineCount: Int
        public let original: String
        public var translation: String?

        public init(x: Double, y: Double, width: Double, height: Double, lineCount: Int, original: String) {
            self.box = [x, y, width, height]
            self.lineCount = max(1, lineCount)
            self.original = original
        }
    }

    /// Off the main queue is fine.
    public static func render(image: UIImage, blocks: [Block]) -> UIImage {
        let size = image.size
        let pixelW = Int(size.width * image.scale)
        let pixelH = Int(size.height * image.scale)
        let sampler = Sampler(image: image)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
            let scale = image.scale
            for block in blocks {
                guard let translation = block.translation, !translation.isEmpty else {
                    continue
                }
                let r = LuckgramImageTranslateLogic.pixelRect(x: block.box[0], y: block.box[1], width: block.box[2], height: block.box[3], imageWidth: pixelW, imageHeight: pixelH)
                let boxW = r[2] - r[0]
                let boxH = r[3] - r[1]
                if boxW < 2 || boxH < 2 {
                    continue
                }
                let lineHeight = boxH / Double(block.lineCount)
                let c = LuckgramImageTranslateLogic.coverRect(r, lineHeight: lineHeight, imageWidth: pixelW, imageHeight: pixelH)
                let (red, green, blue) = sampler.average(around: c)
                let dark = LuckgramImageTranslateLogic.darkText(r: red, g: green, b: blue)
                // points = pixels / scale
                let cover = CGRect(x: c[0] / scale, y: c[1] / scale, width: (c[2] - c[0]) / scale, height: (c[3] - c[1]) / scale)
                let textRect = CGRect(x: r[0] / scale, y: r[1] / scale, width: boxW / scale, height: boxH / scale)
                UIColor(red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: CGFloat(LuckgramImageTranslateLogic.coverAlpha) / 255.0).setFill()
                UIBezierPath(roundedRect: cover, cornerRadius: min(lineHeight / scale * 0.2, 12.0)).fill()

                let color: UIColor = dark ? UIColor(white: 0.07, alpha: 1.0) : .white
                func attributed(_ size: Double) -> NSAttributedString {
                    return NSAttributedString(string: translation, attributes: [.font: UIFont.systemFont(ofSize: CGFloat(size)), .foregroundColor: color])
                }
                let fontSize = LuckgramImageTranslateLogic.fitFontSize(text: translation, width: Double(textRect.width), height: Double(textRect.height), lineHeight: lineHeight / scale, measure: { _, size, width in
                    return Double(attributed(size).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
                })
                let text = attributed(fontSize)
                let height = text.boundingRect(with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
                ctx.cgContext.saveGState()
                ctx.cgContext.clip(to: cover)
                text.draw(with: CGRect(x: textRect.minX, y: textRect.minY + max(0, (textRect.height - height) / 2.0), width: textRect.width, height: max(height, textRect.height)), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                ctx.cgContext.restoreGState()
            }
        }
    }

    /// Average color around a rectangle, read from a downscaled copy (≤ 512 px) of the image.
    private final class Sampler {
        private let width: Int
        private let height: Int
        private let factor: Double
        private var data: [UInt8]

        init(image: UIImage) {
            let pixelW = Double(image.size.width * image.scale)
            let pixelH = Double(image.size.height * image.scale)
            let factor = min(1.0, 512.0 / max(pixelW, pixelH, 1.0))
            self.factor = factor
            self.width = max(1, Int(pixelW * factor))
            self.height = max(1, Int(pixelH * factor))
            self.data = [UInt8](repeating: 255, count: self.width * self.height * 4)
            let width = self.width
            let height = self.height
            self.data.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return
                }
                UIGraphicsPushContext(context)
                // UIKit drawing is top-left origin; flip the bitmap context to match.
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
                UIGraphicsPopContext()
            }
        }

        func average(around c: [Double]) -> (Int, Int, Int) {
            func clampX(_ v: Double) -> Int { min(width - 1, max(0, Int(v * factor))) }
            func clampY(_ v: Double) -> Int { min(height - 1, max(0, Int(v * factor))) }
            let left = clampX(c[0]), right = clampX(c[2] - 1), top = clampY(c[1]), bottom = clampY(c[3] - 1)
            var r = 0, g = 0, b = 0, n = 0
            let steps = 24
            for i in 0 ... steps {
                let x = left + (right - left) * i / steps
                let y = top + (bottom - top) * i / steps
                for (px, py) in [(x, top), (x, bottom), (left, y), (right, y)] {
                    let o = (py * width + px) * 4
                    r += Int(data[o]); g += Int(data[o + 1]); b += Int(data[o + 2]); n += 1
                }
            }
            return n == 0 ? (255, 255, 255) : (r / n, g / n, b / n)
        }
    }

    /// Block index at a normalized point, or nil.
    public static func hitTest(blocks: [Block], x: Double, y: Double) -> Int? {
        return LuckgramImageTranslateLogic.hitTest(boxes: blocks.map(\.box), x: x, y: y)
    }
}
