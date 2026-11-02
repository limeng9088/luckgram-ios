import Foundation
import UIKit
import SwiftSignalKit
import Display
import AccountContext
import PresentationDataUtils
import UndoUI
import CryptoKit

public struct LuckgramAIError: Error, Equatable, CustomStringConvertible {
    // Codes sent by the API server (docs/api-server.md, specs/server/S2, S3)
    public static let quotaExceeded = "quota_exceeded"
    public static let contentRejected = "content_rejected"
    public static let upstreamUnavailable = "upstream_unavailable"
    public static let rateLimited = "rate_limited"
    public static let inputTooLarge = "input_too_large"
    public static let invalidRequest = "invalid_request"
    public static let invalidToken = "invalid_token"
    // Codes produced by the client itself
    public static let networkError = "network_error"
    /// The user declined (or has not given) consent; nothing was sent.
    public static let consentDenied = "consent_denied"
    public static let cancelled = "cancelled"
    /// Telegram refused a request made before the AI call (specs#72), e.g. loading history for a
    /// summary; `telegramCode` and `telegramText` say why.
    public static let telegramError = "telegram_error"

    public let code: String
    public let httpStatus: Int
    /// `error.retry_after_seconds` on 429 responses (S10/S11); 0 if absent.
    public var retryAfterSeconds: Int = 0
    /// For `telegramError`: Telegram's error code and text (e.g. 400, CHANNEL_PRIVATE).
    public var telegramCode: Int = 0
    public var telegramText: String?

    public init(code: String, httpStatus: Int = 0) {
        self.code = code
        self.httpStatus = httpStatus
    }

    /// The error for a failed Telegram request: `telegramError` when Telegram answered with an
    /// error, `networkError` only when no answer came (specs#72).
    public static func fromTelegram(code: Int, text: String?) -> LuckgramAIError {
        if LuckgramTelegramErrorKind.of(code: code, text: text) == .network {
            return LuckgramAIError(code: LuckgramAIError.networkError)
        }
        var error = LuckgramAIError(code: LuckgramAIError.telegramError)
        error.telegramCode = code
        error.telegramText = text
        return error
    }

    /// User-facing message in the current language.
    public var localizedMessage: String {
        if self.code == LuckgramAIError.telegramError {
            return LuckgramStrings.telegramErrorMessage(code: self.telegramCode, text: self.telegramText)
        }
        return LuckgramStrings.errorMessage(self.code)
    }

    public var description: String {
        return "LuckgramAIError(\(self.code), \(self.httpStatus))"
    }
}

/// The only client of the Luckgram API server's AI endpoints. Every AI feature goes through it:
/// device registration, chat (with SSE streaming), image, transcription, quota (`/v1/me`),
/// error messages and the one-time consent dialog.
///
/// Every call takes the `AccountContext` and a `present` closure used to show the consent alert;
/// if consent has not been given and the user declines (or `present` is nil), the signal fails with
/// `LuckgramAIError.consentDenied` and no network request is made. Signals deliver on the main queue.
///
///     LuckgramAI.shared.chat(context: context, present: { [weak self] c in self?.present(c, in: .window(.root)) },
///                            task: .summary, messages: [.user(text)], stream: true)
///     .start(next: { event in ... }, error: { error in LuckgramAI.showError(error, context: context, present: ...) })
public final class LuckgramAI {
    public static let shared = LuckgramAI()

    public enum AITask: String {
        case chat
        case summary
        case reply
        case writing
        case agent
        case post
    }

    public struct Message: Equatable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }

        public static func system(_ content: String) -> Message { Message(role: "system", content: content) }
        public static func user(_ content: String) -> Message { Message(role: "user", content: content) }
        public static func assistant(_ content: String) -> Message { Message(role: "assistant", content: content) }
    }

    public enum ChatEvent: Equatable {
        /// A streamed piece; `text` is everything received so far. Not sent when `stream == false`.
        case delta(String, text: String)
        case completed(String)
    }

    public struct Image {
        /// Temporary link returned by the server.
        public var url: String?
        /// Image bytes (downloaded from `url` with the device token).
        public var data: Data?
        public var mimeType: String
        /// When the temporary link expires (ISO 8601, from the server).
        public var expiresAt: String?
    }

    public struct Transcription: Equatable {
        public var text: String
        public var language: String?
        public var durationSeconds: Double
        /// Number of segments the file was split into (1 unless it was over `ai.transcribe_max_mb`).
        public var segments: Int = 1
        /// Segments transcribed successfully; less than `segments` when `isPartial`.
        public var completedSegments: Int = 0
        /// Set when a later segment failed (e.g. `quota_exceeded`) after earlier ones succeeded: `text`
        /// holds the completed part and this says why the rest is missing (#55). The server charges
        /// each successful segment, so that text is kept instead of discarded.
        public var partialError: LuckgramAIError?

        public var isPartial: Bool {
            return self.partialError != nil
        }
    }

    private static let consentKey = "ai_consent"
    private static let useMockKey = "_ai_use_mock"

    /// In-app mock of the API server, used by the debug page while the server is not live.
    public let mock = LuckgramAIMock()

    private let queue = Queue(name: "LuckgramAI")
    private var token: String?
    private var tokenIsMock = false

    private init() {
    }

    /// API entry in use (debug builds use the dev server; a backup after a network failure, specs#81).
    public static var apiBaseURL: String {
        return LuckgramAI.endpoints.current
    }

    private static let endpointKey = "_api_endpoint"

    /// specs#81: the API entries from Info.plist (`LuckgramAPIURLs`, debug `LuckgramAPIURLsDebug`;
    /// the old single-URL keys still work), starting with the one that worked last.
    public static let endpoints: LuckgramEndpoints = {
        let info = Bundle.main.infoDictionary ?? [:]
        var list: [String] = []
        #if DEBUG
        list = LuckgramEndpoints.parse((info["LuckgramAPIURLsDebug"] as? [String]) ?? [])
        if list.isEmpty, let value = info["LuckgramAPIURLDebug"] as? String {
            list = LuckgramEndpoints.parse([value])
        }
        #endif
        if list.isEmpty {
            list = LuckgramEndpoints.parse((info["LuckgramAPIURLs"] as? [String]) ?? [])
        }
        if list.isEmpty {
            list = LuckgramEndpoints.parse([(info["LuckgramAPIURL"] as? String) ?? ""])
        }
        if list.isEmpty {
            list = ["https://api.luckgram.cc"]
        }
        return LuckgramEndpoints(bases: list, remembered: LuckgramSettings.shared.string(LuckgramAI.endpointKey, default: nil))
    }()

    static func rememberEndpoint(_ base: String) {
        LuckgramSettings.shared.setString(LuckgramAI.endpointKey, base)
    }

    /// A URL from the server pointing at another API entry is moved to the one in use.
    public static func rewriteAPIURL(_ url: String) -> String {
        return LuckgramAI.endpoints.rewrite(url)
    }

    /// While a backup entry is in use, checks the first one in the background (once per cold
    /// start, then every 6 hours) and goes back to it when `GET /v1/health` answers 200.
    static func maybeProbe() {
        let endpoints = LuckgramAI.endpoints
        guard endpoints.takeProbe(now: Date()), let url = URL(string: endpoints.primary + LuckgramEndpoints.healthPath) else {
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10.0
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let proxy = LuckgramNet.shared.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        let start = Date()
        let primary = endpoints.primary
        session.dataTask(with: URLRequest(url: url), completionHandler: { _, response, error in
            let http = response as? HTTPURLResponse
            LuckgramNet.shared.logHTTP(feature: "endpoint-probe", method: "GET", target: url.absoluteString, status: http?.statusCode ?? 0, error: error, start: start, proxy: proxy, requestId: http?.value(forHTTPHeaderField: "X-Request-Id"), endpoint: url.host)
            if http?.statusCode == 200 && endpoints.markWorking(primary) {
                LuckgramAI.rememberEndpoint(primary)
            }
        }).resume()
        session.finishTasksAndInvalidate()
    }

    // MARK: - Mock

    public var isUsingMock: Bool {
        return LuckgramSettings.shared.isDebugToolsVisible && LuckgramSettings.shared.bool(LuckgramAI.useMockKey, default: false)
    }

    public func setUseMock(_ value: Bool) {
        LuckgramSettings.shared.setBool(LuckgramAI.useMockKey, value)
        self.queue.async {
            self.token = nil
        }
    }

    // MARK: - Consent

    public var hasConsent: Bool {
        return LuckgramSettings.shared.bool(LuckgramAI.consentKey, default: false)
    }

    /// Withdraws consent; the next AI call asks again.
    public func revokeConsent() {
        LuckgramSettings.shared.setBool(LuckgramAI.consentKey, false)
    }

    func setConsent(_ value: Bool) {
        LuckgramSettings.shared.setBool(LuckgramAI.consentKey, value)
    }

    /// Shows the consent alert if needed; emits true only if the user agreed.
    public func requestConsent(context: AccountContext?, present: ((ViewController) -> Void)?) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            if self.hasConsent {
                subscriber.putNext(true)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            guard let context, let present else {
                subscriber.putNext(false)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            Queue.mainQueue().async {
                let alert = textAlertController(context: context, title: LuckgramStrings.aiConsentTitle, text: LuckgramStrings.aiConsentText, actions: [
                    TextAlertAction(type: .genericAction, title: LuckgramStrings.aiConsentDecline, action: {
                        subscriber.putNext(false)
                        subscriber.putCompletion()
                    }),
                    TextAlertAction(type: .defaultAction, title: LuckgramStrings.aiConsentAgree, action: {
                        self.setConsent(true)
                        subscriber.putNext(true)
                        subscriber.putCompletion()
                    })
                ], dismissOnOutsideTap: false)
                present(alert)
            }
            return EmptyDisposable
        }
    }

    // MARK: - Local state

    /// Forget the device token (used on logout of the last account and by the debug page).
    public func resetLocalState() {
        self.queue.async {
            self.token = nil
        }
        LuckgramKeychain.delete(account: LuckgramKeychain.deviceTokenAccount)
    }

    public var hasDeviceToken: Bool {
        var result = false
        self.queue.sync {
            result = self.token != nil
        }
        return result || (!self.isUsingMock && LuckgramKeychain.get(account: LuckgramKeychain.deviceTokenAccount) != nil)
    }

    // MARK: - Public API

    /// Fire-and-forget request with the device token held right now (25 nearby: delete my card on
    /// logout). Token, URL and transport are captured before returning, so a `resetLocalState()`
    /// right after (logout of the last account) can't make it register a new device instead.
    public func sendWithCurrentToken(method: String, path: String) {
        let useMock = self.isUsingMock
        var current: String?
        self.queue.sync {
            if let token = self.token, self.tokenIsMock == useMock {
                current = token
            }
        }
        if current == nil && !useMock {
            current = LuckgramKeychain.get(account: LuckgramKeychain.deviceTokenAccount)
        }
        guard let token = current, let url = self.url(path) else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let proxy: String
        if useMock {
            configuration.protocolClasses = [LuckgramAIMockURLProtocol.self]
            proxy = "mock"
        } else {
            proxy = LuckgramNet.shared.apply(to: configuration)
        }
        let session = URLSession(configuration: configuration)
        let start = Date()
        session.dataTask(with: request, completionHandler: { _, response, error in
            let http = response as? HTTPURLResponse
            LuckgramNet.shared.logHTTP(feature: nil, method: method, target: url.absoluteString, status: http?.statusCode ?? 0, error: error, start: start, proxy: proxy, requestId: http?.value(forHTTPHeaderField: "X-Request-Id"))
        }).resume()
        session.finishTasksAndInvalidate()
    }

    /// - Parameter effect: only for `.writing`: one of `polish, formal, friendly, shorter, grammar,
    ///   dictation` (server prompts/writing-*.md), or nil for the default.
    public func chat(context: AccountContext?, present: ((ViewController) -> Void)?, task: AITask, effect: String? = nil, messages: [Message], stream: Bool) -> Signal<ChatEvent, LuckgramAIError> {
        let chars = messages.reduce(0) { $0 + $1.content.count }
        if chars > LuckgramSettings.shared.remoteInt("ai.max_input_chars", default: 60000) {
            return .fail(LuckgramAIError(code: LuckgramAIError.inputTooLarge))
        }
        var body: [String: Any] = [
            "task": task.rawValue,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream
        ]
        if let effect, task == .writing {
            body["effect"] = effect
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
        }
        return self.withConsent(context: context, present: present, self.authorized(method: "POST", path: "/v1/ai/chat", contentType: "application/json", body: payload, accept: stream ? "text/event-stream" : "application/json", feature: task.rawValue)
        |> mapToSignal { event -> Signal<ChatEvent, LuckgramAIError> in
            switch event {
            case let .delta(delta, text):
                return .single(.delta(delta, text: text))
            case let .body(data):
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let text = (object?["text"] as? String) ?? (object?["content"] as? String) ?? ""
                return .single(.completed(text))
            case let .streamEnd(text):
                return .single(.completed(text))
            }
        })
    }

    public func image(context: AccountContext?, present: ((ViewController) -> Void)?, prompt: String) -> Signal<Image, LuckgramAIError> {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["prompt": prompt]) else {
            return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
        }
        return self.withConsent(context: context, present: present, self.authorized(method: "POST", path: "/v1/ai/image", contentType: "application/json", body: payload, accept: "application/json", feature: "image")
        |> mapToSignal { event -> Signal<Image, LuckgramAIError> in
            // docs/api-server.md §3.1: {"url","mime","expires_at"}
            guard case let .body(data) = event, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .complete()
            }
            let info = (object["image"] as? [String: Any]) ?? object
            var image = Image(url: info["url"] as? String, data: (info["b64"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }, mimeType: (info["mime"] as? String) ?? "image/png", expiresAt: info["expires_at"] as? String)
            if image.data != nil {
                return .single(image)
            }
            guard let url = image.url else {
                return .fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
            }
            return self.download(url)
            |> map { bytes -> Image in
                image.data = bytes
                return image
            }
        })
    }

    /// Downloads a temporary file from the API server. The device token is sent only to the API
    /// server's own host (§3.1), never to a third-party host.
    /// Bytes of an https URL (26 square images via CloudFront, or the API host). API-host URLs are
    /// authenticated; others are fetched as is. No consent prompt: nothing of the user's is sent.
    public func fetchData(url: String) -> Signal<Data, LuckgramAIError> {
        return self.download(url)
    }

    /// `PUT` to a presigned upload URL returned by the API server (26 square images). No device
    /// token and no payload-hash header: the URL itself carries the authorization (S3). Completes
    /// when the upload was accepted (2xx), fails otherwise.
    public func putPresigned(url: String, contentType: String, body: Data) -> Signal<Void, LuckgramAIError> {
        guard url.hasPrefix("https://"), let target = URL(string: LuckgramAI.rewriteAPIURL(url)) else {
            return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
        }
        var request = URLRequest(url: target)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return Signal { subscriber in
            let handler = LuckgramHTTPTaskHandler(subscriber: subscriber, feature: "square-upload", method: "PUT", target: url)
            let session = self.session(delegate: handler)
            let task = session.dataTask(with: request)
            task.resume()
            session.finishTasksAndInvalidate()
            return ActionDisposable {
                task.cancel()
            }
        }
        |> map { _ -> Void in
            return Void()
        }
        |> then(.single(Void()))
        |> take(1)
    }

    /// Like `putPresigned(url:contentType:body:)` but streams a file from disk (26 square videos,
    /// up to 50 MB) instead of holding it in memory. `progress` gets the sent fraction (0…1) on an
    /// arbitrary queue.
    public func putPresigned(url: String, contentType: String, fileUrl: URL, progress: ((Double) -> Void)? = nil) -> Signal<Void, LuckgramAIError> {
        guard url.hasPrefix("https://"), let target = URL(string: LuckgramAI.rewriteAPIURL(url)) else {
            return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
        }
        var request = URLRequest(url: target)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return Signal { subscriber in
            let handler = LuckgramHTTPTaskHandler(subscriber: subscriber, feature: "square-upload", method: "PUT", target: url)
            let session = self.session(delegate: handler)
            let task = session.uploadTask(with: request, fromFile: fileUrl)
            var observation: NSKeyValueObservation?
            if let progress = progress {
                observation = task.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                    progress(p.fractionCompleted)
                }
            }
            task.resume()
            session.finishTasksAndInvalidate()
            return ActionDisposable {
                observation?.invalidate()
                observation = nil
                task.cancel()
            }
        }
        |> map { _ -> Void in
            return Void()
        }
        |> then(.single(Void()))
        |> take(1)
    }

    private func download(_ url: String) -> Signal<Data, LuckgramAIError> {
        let signal: Signal<HTTPEvent, LuckgramAIError>
        if self.isAPIHost(url) {
            signal = self.authorized(method: "GET", path: url, contentType: nil, body: nil, accept: "*/*", feature: "media")
        } else if let target = URL(string: url) {
            signal = self.send(URLRequest(url: target), feature: "media")
        } else {
            return .fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
        }
        return signal
        |> mapToSignal { event -> Signal<Data, LuckgramAIError> in
            if case let .body(data) = event, !data.isEmpty {
                return .single(data)
            }
            return .fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
        }
    }

    private func isAPIHost(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else {
            return false
        }
        if self.isUsingMock {
            return host == LuckgramAIMock.host
        }
        return LuckgramAI.endpoints.isEntryHost(host)
    }

    /// Transcribes an audio file; the request body is the audio itself (§3.1 item 5). Files larger
    /// than `ai.transcribe_max_mb` are split by `LuckgramAudioSplitter`, uploaded one after another
    /// and their texts joined in order. Formats that can't be split (MP4/M4A, WebM, FLAC) fail with
    /// `input_too_large` when over the limit.
    ///
    /// - Parameters:
    ///   - mimeType: e.g. `audio/ogg`, `audio/mpeg`, `audio/mp4`, `audio/wav`
    ///   - language: optional ISO-639-1 (2-letter) hint; other values are ignored
    public func transcribe(context: AccountContext?, present: ((ViewController) -> Void)?, audio: Data, mimeType: String, language: String? = nil) -> Signal<Transcription, LuckgramAIError> {
        if audio.isEmpty || !mimeType.hasPrefix("audio/") {
            return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
        }
        let maxBytes = LuckgramSettings.shared.remoteInt("ai.transcribe_max_mb", default: 4) * 1024 * 1024
        guard let segments = LuckgramAudioSplitter.split(audio, mimeType: mimeType, maxBytes: maxBytes), !segments.isEmpty else {
            return .fail(LuckgramAIError(code: LuckgramAIError.inputTooLarge))
        }
        var path = "/v1/ai/transcribe"
        // The server accepts ISO-639-1 (2 letters) only; anything else -> let it auto-detect (#49).
        if let language, language.range(of: "^[a-z]{2}$", options: .regularExpression) != nil {
            path += "?language=\(language)"
        }
        let requestPath = path

        func upload(_ index: Int, _ acc: Transcription) -> Signal<Transcription, LuckgramAIError> {
            if index >= segments.count {
                return .single(acc)
            }
            return (self.authorized(method: "POST", path: requestPath, contentType: mimeType, body: segments[index], accept: "application/json", feature: "transcribe")
            |> mapToSignal { event -> Signal<Transcription, LuckgramAIError> in
                guard case let .body(data) = event, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return .complete()
                }
                var next = acc
                next.text = LuckgramAI.appendTranscript(next.text, (object["text"] as? String) ?? "")
                if next.language == nil {
                    next.language = object["language"] as? String
                }
                next.durationSeconds += ((object["duration_seconds"] as? NSNumber) ?? (object["duration"] as? NSNumber))?.doubleValue ?? 0.0
                next.completedSegments += 1
                return .single(next)
            })
            |> `catch` { error -> Signal<Transcription, LuckgramAIError> in
                // Nothing done yet, or cancelled: a plain error, as before. Otherwise keep what we have.
                if acc.completedSegments == 0 || error.code == LuckgramAIError.cancelled {
                    return .fail(error)
                }
                var partial = acc
                partial.partialError = error
                return .single(partial)
            }
            |> mapToSignal { next -> Signal<Transcription, LuckgramAIError> in
                if next.isPartial || next.completedSegments == acc.completedSegments {
                    return .single(next)
                }
                return upload(index + 1, next)
            }
        }
        return self.withConsent(context: context, present: present, upload(0, Transcription(text: "", language: nil, durationSeconds: 0.0, segments: segments.count)))
    }

    /// Joins segment texts; no space next to CJK characters.
    static func appendTranscript(_ text: String, _ piece: String) -> String {
        let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if piece.isEmpty {
            return text
        }
        if text.isEmpty {
            return piece
        }
        func isCJK(_ c: Character?) -> Bool {
            guard let scalar = c?.unicodeScalars.first?.value else {
                return false
            }
            return (0x3000 ... 0x9FFF).contains(scalar) || (0xAC00 ... 0xD7AF).contains(scalar) || (0xFF00 ... 0xFFEF).contains(scalar)
        }
        if isCJK(text.last) || isCJK(piece.first) {
            return text + piece
        }
        return text + " " + piece
    }

    /// `GET /v1/me`: quota usage and limits, as the raw JSON object.
    public func me(context: AccountContext?, present: ((ViewController) -> Void)?) -> Signal<[String: Any], LuckgramAIError> {
        return self.withConsent(context: context, present: present, self.authorized(method: "GET", path: "/v1/me", contentType: nil, body: nil, accept: "application/json")
        |> mapToSignal { event -> Signal<[String: Any], LuckgramAIError> in
            guard case let .body(data) = event, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .complete()
            }
            return .single(object)
        })
    }

    /// Shows the error's message as a toast.
    public static func showError(_ error: LuckgramAIError, context: AccountContext, present: (ViewController) -> Void) {
        if error.code == LuckgramAIError.cancelled {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: error.localizedMessage, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }

    // MARK: - Internals

    enum HTTPEvent {
        case delta(String, text: String)
        case streamEnd(String)
        case body(Data)
    }

    private func withConsent<T>(context: AccountContext?, present: ((ViewController) -> Void)?, _ signal: Signal<T, LuckgramAIError>) -> Signal<T, LuckgramAIError> {
        return (self.requestConsent(context: context, present: present)
        |> castError(LuckgramAIError.self)
        |> mapToSignal { granted -> Signal<T, LuckgramAIError> in
            if !granted {
                return .fail(LuckgramAIError(code: LuckgramAIError.consentDenied))
            }
            return signal
        })
        |> deliverOnMainQueue
    }

    private func session(delegate: LuckgramHTTPTaskHandler) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120.0
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        if self.isUsingMock {
            configuration.protocolClasses = [LuckgramAIMockURLProtocol.self]
            delegate.proxy = "mock"
        } else {
            // specs#72: through the in-app SOCKS5 proxy when one is on.
            delegate.proxy = LuckgramNet.shared.apply(to: configuration)
        }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// `path` is relative to the API server, or an absolute https URL (temporary files).
    private func url(_ path: String) -> URL? {
        if path.hasPrefix("https://") {
            return URL(string: path)
        }
        if self.isUsingMock {
            return URL(string: "https://\(LuckgramAIMock.host)\(path)")
        }
        return URL(string: LuckgramAI.apiBaseURL + path)
    }

    /// Ensures a device token, sends the request, re-registers once on 401, parses SSE or JSON.
    /// Authenticated GET for non-AI endpoints (remote config, task S4): registers the device if
    /// needed, never asks for AI consent (no user content is sent). Returns the JSON body; a 304
    /// fails with `httpStatus == 304`.
    public func getJSON(path: String, headers: [String: String]) -> Signal<[String: Any], LuckgramAIError> {
        return self.authorized(method: "GET", path: path, contentType: nil, body: nil, accept: "application/json", extraHeaders: headers)
        |> mapToSignal { event -> Signal<[String: Any], LuckgramAIError> in
            guard case let .body(data) = event, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
            }
            return .single(object)
        }
    }

    /// Authenticated JSON request for the account endpoints (S6 link, S7 billing, S8
    /// announcements). Registers the device if needed but never asks for AI consent: nothing but
    /// the device's own state is sent. Delivers on the main queue.
    public func requestJSON(method: String, path: String, body: [String: Any]? = nil) -> Signal<[String: Any], LuckgramAIError> {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let info = Bundle.main.infoDictionary ?? [:]
        var headers: [String: String] = [:]
        if let version = info["CFBundleShortVersionString"] as? String, version.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil {
            headers["X-Luckgram-App-Version"] = version
        }
        return self.authorized(method: method, path: path, contentType: data != nil ? "application/json" : nil, body: data, accept: "application/json", extraHeaders: headers)
        |> mapToSignal { event -> Signal<[String: Any], LuckgramAIError> in
            guard case let .body(data) = event else {
                return .complete()
            }
            if data.isEmpty {
                return .single([:])
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
            }
            return .single(object)
        }
        |> deliverOnMainQueue
    }

    private func authorized(method: String, path: String, contentType: String?, body: Data?, accept: String, extraHeaders: [String: String] = [:], feature: String? = nil) -> Signal<HTTPEvent, LuckgramAIError> {
        func attempt(_ retry: Bool) -> Signal<HTTPEvent, LuckgramAIError> {
            return self.ensureToken()
            |> mapToSignal { token -> Signal<HTTPEvent, LuckgramAIError> in
                guard let url = self.url(path) else {
                    return .fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(accept, forHTTPHeaderField: "Accept")
                if let contentType {
                    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                }
                for (name, value) in extraHeaders {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                request.httpBody = body
                return self.send(request, feature: feature)
                |> `catch` { error -> Signal<HTTPEvent, LuckgramAIError> in
                    if retry && error.httpStatus == 401 {
                        self.queue.async {
                            self.token = nil
                        }
                        if !self.isUsingMock {
                            LuckgramKeychain.delete(account: LuckgramKeychain.deviceTokenAccount)
                        }
                        return attempt(false)
                    }
                    return .fail(error)
                }
            }
        }
        return attempt(true)
    }

    private func ensureToken() -> Signal<String, LuckgramAIError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                let useMock = self.isUsingMock
                if let token = self.token, self.tokenIsMock == useMock {
                    subscriber.putNext(token)
                    subscriber.putCompletion()
                    return
                }
                if !useMock, let stored = LuckgramKeychain.get(account: LuckgramKeychain.deviceTokenAccount) {
                    self.token = stored
                    self.tokenIsMock = false
                    subscriber.putNext(stored)
                    subscriber.putCompletion()
                    return
                }
                guard let url = self.url("/v1/devices") else {
                    subscriber.putError(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let info = Bundle.main.infoDictionary ?? [:]
                let registration: [String: Any] = [
                    "platform": "ios",
                    "app_version": (info["CFBundleShortVersionString"] as? String) ?? "",
                    "locale": LuckgramAI.registrationLocale()
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: registration)
                disposable.set((self.send(request)
                |> mapToSignal { event -> Signal<String, LuckgramAIError> in
                    guard case let .body(data) = event, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let token = (object["token"] as? String) ?? (object["device_token"] as? String), !token.isEmpty else {
                        return .fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
                    }
                    return .single(token)
                }).start(next: { token in
                    self.queue.async {
                        self.token = token
                        self.tokenIsMock = useMock
                        if !useMock {
                            LuckgramKeychain.set(account: LuckgramKeychain.deviceTokenAccount, value: token)
                        }
                        subscriber.putNext(token)
                        subscriber.putCompletion()
                    }
                }, error: { error in
                    subscriber.putError(error)
                }))
            }
            return disposable
        }
    }

    private func send(_ request: URLRequest, feature: String? = nil) -> Signal<HTTPEvent, LuckgramAIError> {
        var signed = request
        if let body = signed.httpBody {
            // CloudFront OAC -> Lambda Function URL requires the payload hash (docs/api-server.md §3.1 item 1).
            signed.setValue(LuckgramAI.sha256Hex(body), forHTTPHeaderField: "x-amz-content-sha256")
        }
        let finalRequest = signed
        // specs#81: an API request goes to the entry in use; if that one can't be reached the same
        // request (full body) goes to the next entry.
        let endpoints = LuckgramAI.endpoints
        let urlString = finalRequest.url?.absoluteString ?? ""
        let own: String? = self.isUsingMock ? nil : endpoints.base(of: urlString)
        let order: [String] = own != nil ? endpoints.attemptOrder() : []
        if own != nil {
            LuckgramAI.maybeProbe()
        }
        return Signal { subscriber in
            let current = LuckgramTaskBox()
            func attempt(_ index: Int) {
                var req = finalRequest
                var entry: String?
                if let own, index < order.count {
                    entry = order[index]
                    req.url = URL(string: order[index] + String(urlString.dropFirst(own.count)))
                }
                let handler = LuckgramHTTPTaskHandler(subscriber: subscriber, feature: feature, method: req.httpMethod, target: req.url?.absoluteString)
                if let entry {
                    handler.endpoint = req.url?.host
                    handler.switched = index > 0
                    handler.onResponse = {
                        if index > 0 && endpoints.markWorking(entry) {
                            LuckgramAI.rememberEndpoint(entry)
                        }
                    }
                    if index + 1 < order.count {
                        let hasBody = req.httpBody != nil
                        handler.retry = { error, bodyBytesSent in
                            guard !current.isCancelled, LuckgramEndpoints.shouldSwitch(domain: error.domain, code: error.code, hasBody: hasBody, bodyBytesSent: bodyBytesSent) else {
                                return false
                            }
                            attempt(index + 1)
                            return true
                        }
                    }
                }
                let session = self.session(delegate: handler)
                let task = session.dataTask(with: req)
                current.set(task)
                task.resume()
                session.finishTasksAndInvalidate()
            }
            attempt(0)
            return ActionDisposable {
                current.cancel()
            }
        }
    }

    static func error(status: Int, data: Data) -> LuckgramAIError {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let error = object["error"] as? [String: Any], let code = error["code"] as? String, !code.isEmpty {
            var result = LuckgramAIError(code: code == "unauthorized" ? LuckgramAIError.invalidToken : code, httpStatus: status)
            result.retryAfterSeconds = max(0, (error["retry_after_seconds"] as? NSNumber)?.intValue ?? 0)
            return result
        }
        let code: String
        switch status {
        case 401:
            code = LuckgramAIError.invalidToken
        case 413:
            code = LuckgramAIError.inputTooLarge
        case 429:
            code = LuckgramAIError.rateLimited
        case 400 ..< 500:
            code = LuckgramAIError.invalidRequest
        default:
            code = LuckgramAIError.upstreamUnavailable
        }
        return LuckgramAIError(code: code, httpStatus: status)
    }

    /// "language[-Script][-REGION]" only, e.g. "zh-Hans-CN" (same as Android). "@rg=…", "@calendar=…"
    /// and other keywords are dropped; the server rejects them (#48).
    static func registrationLocale() -> String {
        let locale = Locale.current
        var parts: [String] = [locale.languageCode ?? "und"]
        if let script = locale.scriptCode, !script.isEmpty {
            parts.append(script)
        }
        if let region = locale.regionCode, !region.isEmpty {
            parts.append(region)
        }
        return parts.joined(separator: "-")
    }

    static func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Mono 16-bit 16 kHz PCM WAV with a 440 Hz tone; used by the debug self-test.
    public static func testToneWav(seconds: Int = 1) -> Data {
        let rate = 16000
        let samples = rate * seconds
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append("RIFF".data(using: .ascii)!)
        le(UInt32(36 + samples * 2))
        data.append("WAVEfmt ".data(using: .ascii)!)
        le(UInt32(16))
        le(UInt16(1))
        le(UInt16(1))
        le(UInt32(rate))
        le(UInt32(rate * 2))
        le(UInt16(2))
        le(UInt16(16))
        data.append("data".data(using: .ascii)!)
        le(UInt32(samples * 2))
        for i in 0 ..< samples {
            le(Int16(sin(2.0 * Double.pi * 440.0 * Double(i) / Double(rate)) * 8000.0))
        }
        return data
    }
}

/// The task of a request that may move to another API entry (specs#81): cancelling cancels
/// whichever attempt is running, and stops further attempts.
private final class LuckgramTaskBox {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    func set(_ task: URLSessionTask) {
        self.lock.lock()
        let cancelled = self.cancelled
        self.task = task
        self.lock.unlock()
        if cancelled {
            task.cancel()
        }
    }

    func cancel() {
        self.lock.lock()
        self.cancelled = true
        let task = self.task
        self.lock.unlock()
        task?.cancel()
    }
}

/// URLSession delegate for one request: buffers JSON bodies, parses `text/event-stream` incrementally.
private final class LuckgramHTTPTaskHandler: NSObject, URLSessionDataDelegate {
    private let subscriber: Subscriber<LuckgramAI.HTTPEvent, LuckgramAIError>
    private var status = 0
    private var isEventStream = false
    private var buffer = Data()
    private var pending = ""
    private var eventName: String?
    private var eventData = ""
    private var fullText = ""
    private var failed = false
    // specs#72: what the diagnostic log records about this request (never the body).
    private let feature: String?
    private let method: String?
    private let target: String?
    private let start = Date()
    var proxy: String?
    private var requestId: String?
    /// specs#81: API entry host used, and whether an earlier entry failed.
    var endpoint: String?
    var switched = false
    /// Called once an HTTP response arrives (the entry works).
    var onResponse: (() -> Void)?
    /// Called when no response arrived; returns true if the request was sent to the next entry,
    /// in which case this handler reports nothing to the subscriber.
    var retry: ((NSError, Int64) -> Bool)?

    init(subscriber: Subscriber<LuckgramAI.HTTPEvent, LuckgramAIError>, feature: String? = nil, method: String? = nil, target: String? = nil) {
        self.subscriber = subscriber
        self.feature = feature
        self.method = method
        self.target = target
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let response = response as? HTTPURLResponse {
            self.status = response.statusCode
            self.requestId = response.value(forHTTPHeaderField: "X-Request-Id")
            self.onResponse?()
            self.onResponse = nil
            let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            self.isEventStream = self.status < 300 && contentType.hasPrefix("text/event-stream")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !self.isEventStream {
            self.buffer.append(data)
            return
        }
        self.buffer.append(data)
        // Only decode complete UTF-8 lines.
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            let lineData = self.buffer.subdata(in: self.buffer.startIndex ..< newline)
            self.buffer.removeSubrange(self.buffer.startIndex ... newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            self.handleLine(line)
            if self.failed {
                dataTask.cancel()
                return
            }
        }
    }

    private func handleLine(_ line: String) {
        if line.isEmpty {
            self.dispatchEvent()
        } else if line.hasPrefix("event:") {
            self.eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            if !self.eventData.isEmpty {
                self.eventData.append("\n")
            }
            self.eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
    }

    private func dispatchEvent() {
        defer {
            self.eventName = nil
            self.eventData = ""
        }
        if self.eventData.isEmpty || self.eventData == "[DONE]" {
            return
        }
        guard let data = self.eventData.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        if self.eventName == "error" || object["error"] != nil {
            self.failed = true
            self.subscriber.putError(LuckgramAI.error(status: self.status, data: data))
            return
        }
        var delta = object["delta"] as? String
        if delta == nil, let choices = object["choices"] as? [[String: Any]], let d = choices.first?["delta"] as? [String: Any] {
            // Also accept OpenAI-style chunks.
            delta = d["content"] as? String
        }
        if let delta, !delta.isEmpty {
            self.fullText.append(delta)
            self.subscriber.putNext(.delta(delta, text: self.fullText))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if (task.response as? HTTPURLResponse) != nil && self.status == 0 {
            self.status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        }
        if self.status == 0, let error = error as NSError?, let retry = self.retry, retry(error, task.countOfBytesSent) {
            // logged as its own line; the next entry's line says switched=1
            LuckgramNet.shared.logHTTP(feature: "endpoint-switch", method: self.method, target: self.target, status: 0, error: error, start: self.start, proxy: self.proxy, requestId: nil, endpoint: self.endpoint, switched: self.switched)
            return
        }
        LuckgramNet.shared.logHTTP(feature: self.feature, method: self.method, target: self.target, status: self.status, error: self.status > 0 ? nil : error, start: self.start, proxy: self.proxy, requestId: self.requestId ?? (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Request-Id"), endpoint: self.endpoint, switched: self.switched)
        if self.failed {
            return
        }
        if let error = error as NSError? {
            let code = error.code == NSURLErrorCancelled ? LuckgramAIError.cancelled : LuckgramAIError.networkError
            self.subscriber.putError(LuckgramAIError(code: code))
            return
        }
        if self.status >= 300 || self.status == 0 {
            self.subscriber.putError(LuckgramAI.error(status: self.status, data: self.buffer))
            return
        }
        if self.isEventStream {
            if !self.buffer.isEmpty {
                self.handleLine(String(decoding: self.buffer, as: UTF8.self))
                self.buffer.removeAll()
            }
            self.dispatchEvent()
            if self.failed {
                return
            }
            self.subscriber.putNext(.streamEnd(self.fullText))
        } else {
            self.subscriber.putNext(.body(self.buffer))
        }
        self.subscriber.putCompletion()
    }
}
