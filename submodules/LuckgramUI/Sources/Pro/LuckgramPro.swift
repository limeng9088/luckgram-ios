import Foundation
import SwiftSignalKit

/// specs#87 (29): the one place that says whether the user has Luckgram Pro. Every Pro check goes
/// through `isPro`; perks, AI credits and limits come from the same `LuckgramProState`.
///
/// Refreshed from `GET /v1/me` when the app comes to the foreground (`refreshIfStale()`), on the
/// Pro page and after a payment (`refresh()`). The last answer is cached, so offline the user
/// stays Pro until the cached `expires_at`. `stateSignal` emits when what a user would see changes.
/// No AI consent is asked: nothing of the user's is sent.
public final class LuckgramPro {
    public static let shared = LuckgramPro()

    private static let cacheKey = "_pro_state"
    /// Back to foreground more often than this doesn't ask the server again.
    static let minRefreshInterval: TimeInterval = 60.0

    private let statePromise: ValuePromise<LuckgramProState>
    private var currentState: LuckgramProState
    private var inFlight = false
    private var lastRequest: Date?
    private let request = MetaDisposable()

    private init() {
        let cached = LuckgramProState.fromCache(LuckgramSettings.shared.string(LuckgramPro.cacheKey, default: nil))
        self.currentState = cached
        self.statePromise = ValuePromise(cached, ignoreRepeated: true)
    }

    public var state: LuckgramProState {
        return self.currentState
    }

    /// Current state, then every change (main queue).
    public var stateSignal: Signal<LuckgramProState, NoError> {
        return self.statePromise.get()
    }

    public var isPro: Bool {
        return self.currentState.isPro(now: Date())
    }

    public func hasPerk(_ perk: String) -> Bool {
        return self.currentState.hasPerk(perk)
    }

    public var credits: Int {
        return self.currentState.credits(now: Date())
    }

    /// Back to foreground: asks the server unless it did within the last minute.
    public func refreshIfStale() {
        if let last = self.lastRequest, Date().timeIntervalSince(last) < LuckgramPro.minRefreshInterval {
            return
        }
        self.refresh()
    }

    /// Asks the server now (Pro page, after a payment). One request at a time. Main queue.
    public func refresh() {
        if self.inFlight {
            return
        }
        self.inFlight = true
        self.lastRequest = Date()
        self.request.set((LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/me")
        |> deliverOnMainQueue).start(next: { [weak self] j in
            guard let self else {
                return
            }
            self.inFlight = false
            self.update(LuckgramProState.parse(j, now: Date()))
        }, error: { [weak self] _ in
            // keep the cached state (offline: Pro until the cached expiry)
            self?.inFlight = false
        }))
    }

    private func update(_ next: LuckgramProState) {
        self.currentState = next
        LuckgramSettings.shared.setString(LuckgramPro.cacheKey, next.toCache())
        self.statePromise.set(next)
    }
}
