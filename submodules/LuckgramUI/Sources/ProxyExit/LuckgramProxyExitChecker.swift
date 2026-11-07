import Foundation
import Network
import SwiftSignalKit

/// specs#117: checks and caches the exit IP / country of the direct connection and of each SOCKS5
/// proxy for the proxy list. The request goes to the Luckgram server (`/v1/net/whoami`) — directly
/// with every system proxy disabled, or through the SOCKS5 proxy with its username/password
/// (iOS 17+; older systems only show the direct exit). At most 4 checks run at once; results live
/// in memory only and are never logged.
public final class LuckgramProxyExitChecker {
    public static let shared = LuckgramProxyExitChecker()
    public static let directKey = "direct"

    public enum State: Equatable {
        case checking
        case failed
        case done(LuckgramProxyExit)
    }

    public struct Socks: Equatable {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String

        public init(host: String, port: Int, username: String?, password: String?) {
            self.host = host
            self.port = port
            self.username = username ?? ""
            self.password = password ?? ""
        }
    }

    private let queue = DispatchQueue(label: "LuckgramProxyExitChecker")
    private var states: [String: State] = [:]
    private var checkedAt: [String: Date] = [:]
    private var pending: [(String, Socks?)] = []
    private var running = 0
    private var inFlight = Set<String>()
    private let statesPromise = ValuePromise<[String: State]>([:], ignoreRepeated: true)

    private init() {
    }

    /// True when proxy exits can be checked on this system.
    public static var supportsProxyExit: Bool {
        if #available(iOS 17.0, *) {
            return true
        }
        return false
    }

    /// Cache key of a SOCKS5 proxy (credentials hashed, so an edited proxy is checked again);
    /// nil when its exit cannot be checked.
    public static func key(_ socks: Socks) -> String? {
        guard supportsProxyExit, !socks.host.isEmpty, socks.port > 0, socks.port < 65536 else {
            return nil
        }
        return "s5:\(socks.host.lowercased()):\(socks.port):\(socks.username):\(socks.password.hashValue)"
    }

    public func statesSignal() -> Signal<[String: State], NoError> {
        return self.statesPromise.get()
    }

    /// Starts checks for the direct connection and these proxies unless a fresh result or a running
    /// check exists. `force` checks everything again.
    public func ensure(proxies: [Socks], force: Bool) {
        self.queue.async {
            var items: [(String, Socks?)] = [(LuckgramProxyExitChecker.directKey, nil)]
            for p in proxies {
                if let key = LuckgramProxyExitChecker.key(p) {
                    items.append((key, p))
                }
            }
            let now = Date()
            var changed = false
            for (key, socks) in items {
                if self.inFlight.contains(key) || self.pending.contains(where: { $0.0 == key }) {
                    continue
                }
                if !force && self.states[key] != nil && LuckgramProxyExit.isFresh(checkedAt: self.checkedAt[key], now: now) {
                    continue
                }
                // An old result stays visible while it is checked again.
                if self.states[key] == nil || self.states[key] == .failed {
                    self.states[key] = .checking
                    changed = true
                }
                self.pending.append((key, socks))
            }
            if changed {
                self.statesPromise.set(self.states)
            }
            self.pump()
        }
    }

    private func pump() {
        while self.running < 4, !self.pending.isEmpty {
            let (key, socks) = self.pending.removeFirst()
            self.inFlight.insert(key)
            self.running += 1
            self.fetch(socks: socks) { [weak self] exit in
                guard let self = self else {
                    return
                }
                self.queue.async {
                    self.running -= 1
                    self.inFlight.remove(key)
                    self.checkedAt[key] = Date()
                    if let exit = exit {
                        self.states[key] = .done(exit)
                    } else {
                        self.states[key] = .failed
                    }
                    self.statesPromise.set(self.states)
                    self.pump()
                }
            }
        }
    }

    /// specs#81: tries the API entries in order; a network-level failure moves on to the next one
    /// (the main entry can be blocked where a backup still works), any HTTP answer stops.
    private func fetch(socks: Socks?, completion: @escaping (LuckgramProxyExit?) -> Void) {
        self.fetch(socks: socks, bases: LuckgramAI.endpoints.attemptOrder()[...], completion: completion)
    }

    private func fetch(socks: Socks?, bases: ArraySlice<String>, completion: @escaping (LuckgramProxyExit?) -> Void) {
        guard let base = bases.first, let url = URL(string: base + LuckgramProxyExit.path) else {
            completion(nil)
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        if let socks = socks {
            if #available(iOS 17.0, *), let port = NWEndpoint.Port(rawValue: UInt16(socks.port)) {
                var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(socks.host), port: port))
                if !socks.username.isEmpty {
                    proxy.applyCredential(username: socks.username, password: socks.password)
                }
                config.proxyConfigurations = [proxy]
            } else {
                completion(nil)
                return
            }
        } else {
            // An empty dictionary means "no proxy", ignoring the system HTTP proxy too.
            config.connectionProxyDictionary = [:]
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let http = response as? HTTPURLResponse else {
                if let self = self, bases.count > 1 {
                    self.fetch(socks: socks, bases: bases.dropFirst(), completion: completion)
                } else {
                    completion(nil)
                }
                return
            }
            var exit: LuckgramProxyExit?
            if http.statusCode / 100 == 2, let data = data {
                exit = LuckgramProxyExit.parse(data)
            }
            completion(exit)
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }
}
