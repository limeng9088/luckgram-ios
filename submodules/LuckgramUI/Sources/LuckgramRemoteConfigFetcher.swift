import Foundation
import SwiftSignalKit

/// Fetches `GET /v1/config` (task S4) into `LuckgramSettings.mergeRemoteConfig`.
///
/// - Runs when the app comes to the foreground and the cached config is older than its `ttl`;
///   sends `If-None-Match` with `LuckgramSettings.remoteConfigVersion`, so an unchanged config is
///   a 304.
/// - A failed fetch (offline, server down) keeps the cached config and is retried after
///   `LuckgramRemoteConfigLogic.retryAfterFailureSeconds`; without a cache every feature uses its
///   built-in default.
/// - Only registers the anonymous device (platform, version, locale); no user content is sent, so
///   no AI consent is needed.
public final class LuckgramRemoteConfigFetcher {
    public static let shared = LuckgramRemoteConfigFetcher()

    private static let appVersionHeader = "X-Luckgram-App-Version"

    private let disposable = MetaDisposable()
    private var inFlight = false
    private var lastFailure: Double = 0.0

    private init() {
    }

    private var now: Double {
        return Date().timeIntervalSince1970
    }

    /// Refreshes if the cached config has expired. Main queue.
    public func refreshIfStale() {
        let cached = LuckgramSettings.shared.remoteConfig
        let ttl = cached.ttlSeconds > 0.0 ? cached.ttlSeconds : LuckgramRemoteConfigLogic.defaultTTLSeconds
        if LuckgramRemoteConfigLogic.isStale(now: self.now, fetchedAt: cached.fetchedAt, ttlSeconds: ttl, lastFailure: self.lastFailure) {
            self.refresh()
        }
    }

    /// Refreshes now. Main queue.
    public func refresh() {
        if self.inFlight || LuckgramAI.apiBaseURL.isEmpty {
            return
        }
        self.inFlight = true
        var headers: [String: String] = [:]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            headers[LuckgramRemoteConfigFetcher.appVersionHeader] = version
        }
        if let version = LuckgramSettings.shared.remoteConfigVersion, !version.isEmpty {
            headers["If-None-Match"] = "\"\(version)\""
        }
        self.disposable.set((LuckgramAI.shared.getJSON(path: "/v1/config", headers: headers)
        |> deliverOnMainQueue).start(next: { [weak self] body in
            LuckgramSettings.shared.mergeRemoteConfig(body)
            self?.lastFailure = 0.0
            self?.inFlight = false
        }, error: { [weak self] error in
            guard let self else {
                return
            }
            if error.httpStatus == 304 {
                LuckgramSettings.shared.touchRemoteConfig() // unchanged: restart the TTL only
                self.lastFailure = 0.0
            } else {
                self.lastFailure = self.now
            }
            self.inFlight = false
        }))
    }
}
