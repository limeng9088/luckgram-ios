import Foundation
import Network

/// specs#72: network plumbing shared by every request to the Luckgram API.
///
/// - Requests follow the in-app Telegram proxy when it is SOCKS5. The app passes the active proxy
///   in with `setProxy` whenever it changes (SharedAccountContext), so turning it off applies at
///   once. MTProto and web proxies can't carry HTTP: those requests go direct.
/// - Every request is written to a local diagnostic log (metadata only, see `LuckgramDiagLog`),
///   kept for 7 days / 2 MB and exported as .txt from the Luckgram settings page. Always on.
public final class LuckgramNet {
    public static let shared = LuckgramNet()

    /// The in-app proxy as Telegram has it; `type` is `SOCKS5`, `MTPROTO` or `WEB`.
    public struct Proxy: Equatable {
        public var type: String
        public var host: String
        public var port: Int
        public var username: String?
        public var password: String?

        public init(type: String, host: String, port: Int, username: String? = nil, password: String? = nil) {
            self.type = type
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    private let lock = NSLock()
    private var proxy: Proxy?
    private let writeQueue = DispatchQueue(label: "LuckgramDiag")
    private var trimmedThisRun = false

    private init() {
    }

    /// Called by the app with the active proxy, or nil when the proxy is off.
    public func setProxy(_ proxy: Proxy?) {
        self.lock.lock()
        self.proxy = proxy
        self.lock.unlock()
    }

    private var currentProxy: Proxy? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.proxy
    }

    /// The route label for a request starting now.
    public var currentRouteLabel: String {
        let p = self.currentProxy
        return LuckgramProxyRoute.decide(enabled: p != nil, type: p?.type, host: p?.host, port: p?.port ?? 0)
    }

    /// Points `configuration` at the in-app SOCKS5 proxy if one is on; returns the route label.
    @discardableResult
    public func apply(to configuration: URLSessionConfiguration) -> String {
        let p = self.currentProxy
        let label = LuckgramProxyRoute.decide(enabled: p != nil, type: p?.type, host: p?.host, port: p?.port ?? 0)
        guard label == LuckgramProxyRoute.socks5, let p else {
            return label
        }
        let user = p.username ?? ""
        let pass = p.password ?? ""
        if #available(iOS 17.0, *), let port = NWEndpoint.Port(rawValue: UInt16(p.port)) {
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(p.host), port: port))
            if !user.isEmpty {
                proxy.applyCredential(username: user, password: pass)
            }
            configuration.proxyConfigurations = [proxy]
        } else {
            var dict: [AnyHashable: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": p.host,
                "SOCKSPort": p.port
            ]
            if !user.isEmpty {
                dict[kCFStreamPropertySOCKSUser as String] = user
                dict[kCFStreamPropertySOCKSPassword as String] = pass
            }
            configuration.connectionProxyDictionary = dict
        }
        return label
    }

    // MARK: - Diagnostic log

    public static var apiHost: String? {
        return URL(string: LuckgramAI.apiBaseURL)?.host
    }

    /// Logs one finished Luckgram API request.
    public func logHTTP(feature: String?, method: String?, target: String?, status: Int, error: Error?, start: Date, proxy: String?, requestId: String?) {
        var e = LuckgramDiagLog.Entry()
        e.timeMs = Int64(start.timeIntervalSince1970 * 1000)
        e.feature = feature
        e.method = method
        e.target = target
        e.status = status
        if let error = error as NSError? {
            e.failure = "\(error.domain)\(error.code)"
        }
        e.durationMs = max(0, Int64(Date().timeIntervalSince(start) * 1000))
        e.proxy = proxy
        e.requestId = requestId
        self.log(e)
    }

    /// Logs a failed Telegram request made before an AI request (e.g. history for a summary).
    public func logTelegram(feature: String, method: String, code: Int, text: String?) {
        var e = LuckgramDiagLog.Entry()
        e.timeMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.feature = feature
        e.target = method
        e.tgCode = code
        e.tgError = text ?? ""
        self.log(e)
    }

    public func log(_ entry: LuckgramDiagLog.Entry) {
        let line = LuckgramDiagLog.format(entry, apiHost: LuckgramNet.apiHost)
        self.writeQueue.async {
            guard let url = LuckgramNet.logURL() else {
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if !self.trimmedThisRun || size > LuckgramDiagLog.maxBytes {
                self.trimmedThisRun = true
                LuckgramNet.rewriteTrimmed(url)
            }
            guard let data = (line + "\n").data(using: .utf8) else {
                return
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func logURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("luckgram", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.log")
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func rewriteTrimmed(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        // Leave room for new lines so the file isn't rewritten on every request near the limit.
        let kept = LuckgramDiagLog.trim(readLines(url), nowMs: Int64(Date().timeIntervalSince1970 * 1000), maxAge: LuckgramDiagLog.maxAge, maxBytes: LuckgramDiagLog.maxBytes * 3 / 4)
        let text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Writes the log to a .txt in the temporary directory; nil if there is nothing to export.
    /// `completion` runs on the main queue.
    public func exportFile(completion: @escaping (URL?) -> Void) {
        self.writeQueue.async {
            var result: URL?
            if let src = LuckgramNet.logURL() {
                LuckgramNet.rewriteTrimmed(src)
                let lines = LuckgramNet.readLines(src)
                if !lines.isEmpty {
                    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    if let old = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                        for name in old where name.hasPrefix("luckgram-diag-") && name.hasSuffix(".txt") {
                            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                        }
                    }
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "yyyyMMdd-HHmm"
                    let out = dir.appendingPathComponent("luckgram-diag-\(f.string(from: Date())).txt")
                    let info = Bundle.main.infoDictionary ?? [:]
                    var text = "Luckgram diagnostic log\n"
                    text += "app=\((info["CFBundleShortVersionString"] as? String) ?? "") (\((info["CFBundleVersion"] as? String) ?? "")) ios=\(ProcessInfo.processInfo.operatingSystemVersionString)\n"
                    text += "server=\(LuckgramDiagLog.route(LuckgramAI.apiBaseURL, apiHost: nil)) proxy_now=\(self.currentRouteLabel)\n\n"
                    text += lines.joined(separator: "\n") + "\n"
                    if (try? text.data(using: .utf8)?.write(to: out, options: .atomic)) != nil {
                        result = out
                    }
                }
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
