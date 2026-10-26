import Foundation

/// In-app mock of the Luckgram API server (same paths, bodies and error format as
/// docs/api-server.md). Plugged into URLSession as a URLProtocol, so the real client code
/// (request building, SSE parsing, re-registration) runs unchanged; nothing leaves the device.
public final class LuckgramAIMock {
    /// Host of every mock URL (API paths and temporary image files).
    public static let host = "luckgram-mock.invalid"
    static let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private let lock = NSLock()
    private var requests = 0
    private var chats = 0
    private var forcedError: String?
    private var chatLimit = 50
    private var transcribeCalls = 0

    /// Number of /v1/ai/transcribe requests so far (one per uploaded segment).
    public var transcribeCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.transcribeCalls
    }

    public var requestCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requests
    }

    /// Next request (other than registration) fails with this error code.
    public func failNext(_ code: String) {
        self.lock.lock()
        self.forcedError = code
        self.lock.unlock()
    }

    public func setChatLimit(_ limit: Int) {
        self.lock.lock()
        self.chatLimit = limit
        self.chats = 0
        self.lock.unlock()
    }

    enum Response {
        case json(Int, [String: Any])
        case sse([String])
        case raw(Int, String, Data)
    }

    func handle(method: String, path: String, query: String?, headers: [String: String], body: Data) -> Response {
        self.lock.lock()
        self.requests += 1
        self.lock.unlock()

        // CloudFront OAC: a request with a body and no / a wrong payload hash is rejected with 403.
        if !body.isEmpty {
            let sent = headers.first(where: { $0.key.lowercased() == "x-amz-content-sha256" })?.value
            if sent != LuckgramAI.sha256Hex(body) {
                return .json(403, ["message": "Forbidden"])
            }
        }

        if method == "POST" && path == "/v1/devices" {
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], object["platform"] != nil else {
                return LuckgramAIMock.error(400, "invalid_request")
            }
            return .json(200, ["token": "mock_\(UInt64.random(in: 0 ..< UInt64.max))"])
        }
        guard let auth = headers["Authorization"], auth.hasPrefix("Bearer mock_") else {
            return LuckgramAIMock.error(401, "invalid_token")
        }
        self.lock.lock()
        let forced = self.forcedError
        self.forcedError = nil
        self.lock.unlock()
        if let forced {
            let status = (forced == "quota_exceeded" || forced == "rate_limited") ? 429 : (forced == "content_rejected" ? 422 : 503)
            return LuckgramAIMock.error(status, forced)
        }
        switch path {
        case "/v1/ai/chat":
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let messages = object["messages"] as? [Any] else {
                return LuckgramAIMock.error(400, "invalid_request")
            }
            self.lock.lock()
            self.chats += 1
            let overLimit = self.chats > self.chatLimit
            self.lock.unlock()
            if overLimit {
                return LuckgramAIMock.error(429, "quota_exceeded")
            }
            let task = (object["task"] as? String) ?? ""
            let reply = LuckgramStrings.isChinese ? "Mock 回复：收到 \(messages.count) 条消息，task = \(task)。" : "Mock reply: got \(messages.count) message(s), task = \(task)."
            if (object["stream"] as? Bool) != true {
                return .json(200, ["text": reply])
            }
            var events: [String] = []
            var index = reply.startIndex
            while index < reply.endIndex {
                let end = reply.index(index, offsetBy: 2, limitedBy: reply.endIndex) ?? reply.endIndex
                let piece = String(reply[index ..< end])
                if let data = try? JSONSerialization.data(withJSONObject: ["delta": piece]), let json = String(data: data, encoding: .utf8) {
                    events.append("data: \(json)\n\n")
                }
                index = end
            }
            events.append("data: {\"done\":true}\n\n")
            return .sse(events)
        case "/v1/ai/image":
            return .json(200, ["url": "https://\(LuckgramAIMock.host)/v1/ai/image/files/mock.png", "mime": "image/png", "expires_at": "2099-01-01T00:00:00Z"])
        case "/v1/ai/image/files/mock.png":
            return .raw(200, "image/png", Data(base64Encoded: LuckgramAIMock.tinyPNG) ?? Data())
        case "/v1/ai/transcribe":
            let contentType = headers.first(where: { $0.key.lowercased() == "content-type" })?.value ?? ""
            if !contentType.hasPrefix("audio/") || body.isEmpty {
                return LuckgramAIMock.error(400, "invalid_request")
            }
            if body.count > LuckgramSettings.shared.remoteInt("ai.transcribe_max_mb", default: 4) * 1024 * 1024 {
                return LuckgramAIMock.error(413, "input_too_large")
            }
            self.lock.lock()
            self.transcribeCalls += 1
            let n = self.transcribeCalls
            self.lock.unlock()
            var language = "zh"
            if let query, query.hasPrefix("language=") {
                language = String(query.dropFirst("language=".count))
            }
            if language.range(of: "^[a-z]{2}$", options: .regularExpression) == nil {
                return LuckgramAIMock.error(400, "invalid_request")
            }
            let text = LuckgramStrings.isChinese ? "第\(n)段（\(body.count) 字节）。" : "Segment \(n) (\(body.count) bytes)."
            return .json(200, ["text": text, "language": language, "duration_seconds": Double(body.count) / 32000.0, "model": "mock"])
        case "/v1/me":
            self.lock.lock()
            let used = self.chats
            let limit = self.chatLimit
            self.lock.unlock()
            return .json(200, ["plan": "free", "quota": [
                "chat": ["used": used, "limit": limit],
                "image": ["used": 0, "limit": 5],
                "transcribe_minutes": ["used": 0, "limit": 30]
            ]])
        default:
            return LuckgramAIMock.error(404, "not_found")
        }
    }

    private static func error(_ status: Int, _ code: String) -> Response {
        return .json(status, ["error": ["code": code, "message": code]])
    }
}

final class LuckgramAIMockURLProtocol: URLProtocol {
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        return request.url?.host == LuckgramAIMock.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        var data = Data()
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 {
                break
            }
            data.append(buffer, count: n)
        }
        stream.close()
        return data
    }

    override func startLoading() {
        let request = self.request
        guard let url = request.url else {
            return
        }
        let response = LuckgramAI.shared.mock.handle(method: request.httpMethod ?? "GET", path: url.path, query: url.query, headers: request.allHTTPHeaderFields ?? [:], body: LuckgramAIMockURLProtocol.bodyData(request))
        switch response {
        case let .json(status, object):
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        case let .raw(status, contentType, data):
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        case let .sse(events):
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.sendEvents(events, index: 0)
        }
    }

    /// Streams events 40 ms apart, like the real server.
    private func sendEvents(_ events: [String], index: Int) {
        if self.stopped {
            return
        }
        if index >= events.count {
            self.client?.urlProtocolDidFinishLoading(self)
            return
        }
        self.client?.urlProtocol(self, didLoad: Data(events[index].utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.sendEvents(events, index: index + 1)
        }
    }

    override func stopLoading() {
        self.stopped = true
    }
}
