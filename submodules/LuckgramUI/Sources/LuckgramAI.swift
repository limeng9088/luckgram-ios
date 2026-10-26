import Foundation
import UIKit
import SwiftSignalKit
import Display
import AccountContext
import PresentationDataUtils
import UndoUI

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

    public let code: String
    public let httpStatus: Int

    public init(code: String, httpStatus: Int = 0) {
        self.code = code
        self.httpStatus = httpStatus
    }

    /// User-facing message in the current language.
    public var localizedMessage: String {
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
        /// Temporary link returned by the server (nil if the server returned bytes).
        public var url: String?
        public var data: Data?
        public var mimeType: String
    }

    public struct Transcription: Equatable {
        public var text: String
        public var language: String?
        public var durationSeconds: Double
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

    /// API server base URL from the build configuration (Info.plist; debug builds use the dev server).
    public static var apiBaseURL: String {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        if let value = info["LuckgramAPIURLDebug"] as? String, !value.isEmpty {
            return value
        }
        #endif
        return (info["LuckgramAPIURL"] as? String) ?? ""
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

    public func chat(context: AccountContext?, present: ((ViewController) -> Void)?, task: AITask, messages: [Message], stream: Bool) -> Signal<ChatEvent, LuckgramAIError> {
        let chars = messages.reduce(0) { $0 + $1.content.count }
        if chars > LuckgramSettings.shared.remoteInt("ai.max_input_chars", default: 60000) {
            return .fail(LuckgramAIError(code: LuckgramAIError.inputTooLarge))
        }
        let body: [String: Any] = [
            "task": task.rawValue,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
        }
        return self.withConsent(context: context, present: present, self.authorized(method: "POST", path: "/v1/ai/chat", contentType: "application/json", body: payload, accept: stream ? "text/event-stream" : "application/json")
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
        return self.withConsent(context: context, present: present, self.authorized(method: "POST", path: "/v1/ai/image", contentType: "application/json", body: payload, accept: "application/json")
        |> mapToSignal { event -> Signal<Image, LuckgramAIError> in
            guard case let .body(data) = event, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .complete()
            }
            let image = (object["image"] as? [String: Any]) ?? object
            let url = image["url"] as? String
            let bytes = (image["b64"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            if url == nil && bytes == nil {
                return .fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
            }
            return .single(Image(url: url, data: bytes, mimeType: (image["mime"] as? String) ?? "image/png"))
        })
    }

    /// - Parameters:
    ///   - mimeType: e.g. `audio/ogg`, `audio/mp4`, `audio/wav`
    ///   - language: optional ISO-639-1 hint
    public func transcribe(context: AccountContext?, present: ((ViewController) -> Void)?, audio: Data, mimeType: String, language: String? = nil) -> Signal<Transcription, LuckgramAIError> {
        let maxBytes = LuckgramSettings.shared.remoteInt("ai.transcribe_max_mb", default: 25) * 1024 * 1024
        if audio.isEmpty {
            return .fail(LuckgramAIError(code: LuckgramAIError.invalidRequest))
        }
        if audio.count > maxBytes {
            return .fail(LuckgramAIError(code: LuckgramAIError.inputTooLarge))
        }
        let boundary = "luckgram\(UInt64.random(in: 0 ..< UInt64.max))"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(LuckgramAI.fileExtension(mimeType))\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        if let language, !language.isEmpty {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return self.withConsent(context: context, present: present, self.authorized(method: "POST", path: "/v1/ai/transcribe", contentType: "multipart/form-data; boundary=\(boundary)", body: body, accept: "application/json")
        |> mapToSignal { event -> Signal<Transcription, LuckgramAIError> in
            guard case let .body(data) = event, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .complete()
            }
            return .single(Transcription(text: (object["text"] as? String) ?? "", language: object["language"] as? String, durationSeconds: (object["duration"] as? NSNumber)?.doubleValue ?? 0.0))
        })
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

    private func session(delegate: URLSessionDataDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120.0
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        if self.isUsingMock {
            configuration.protocolClasses = [LuckgramAIMockURLProtocol.self]
        }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func url(_ path: String) -> URL? {
        if self.isUsingMock {
            return URL(string: "https://luckgram-mock.invalid\(path)")
        }
        return URL(string: LuckgramAI.apiBaseURL + path)
    }

    /// Ensures a device token, sends the request, re-registers once on 401, parses SSE or JSON.
    private func authorized(method: String, path: String, contentType: String?, body: Data?, accept: String) -> Signal<HTTPEvent, LuckgramAIError> {
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
                request.httpBody = body
                return self.send(request)
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
                    "locale": Locale.current.identifier
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

    private func send(_ request: URLRequest) -> Signal<HTTPEvent, LuckgramAIError> {
        return Signal { subscriber in
            let handler = LuckgramHTTPTaskHandler(subscriber: subscriber)
            let session = self.session(delegate: handler)
            let task = session.dataTask(with: request)
            task.resume()
            session.finishTasksAndInvalidate()
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    static func error(status: Int, data: Data) -> LuckgramAIError {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let error = object["error"] as? [String: Any], let code = error["code"] as? String, !code.isEmpty {
            return LuckgramAIError(code: code == "unauthorized" ? LuckgramAIError.invalidToken : code, httpStatus: status)
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

    static func fileExtension(_ mimeType: String) -> String {
        switch mimeType {
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/mp4", "audio/m4a", "audio/aac", "audio/x-m4a":
            return "m4a"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/webm":
            return "webm"
        default:
            return "ogg"
        }
    }

    /// Mono 16-bit PCM WAV with a 1 s 440 Hz tone; used by the debug self-test.
    public static func testToneWav() -> Data {
        let rate = 16000
        let samples = rate
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

    init(subscriber: Subscriber<LuckgramAI.HTTPEvent, LuckgramAIError>) {
        self.subscriber = subscriber
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let response = response as? HTTPURLResponse {
            self.status = response.statusCode
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
