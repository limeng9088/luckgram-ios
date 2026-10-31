import Foundation
import SwiftSignalKit

/// Chat-list announcements (task S8): fetched with `GET /v1/announcements` when the app comes to
/// the foreground (at most every 30 minutes), shown as the notice on top of the main chat list
/// (GlobalControlPanelsContext), one at a time. Closing it remembers its ID on this device so it
/// does not come back; an announcement past its end time disappears even before the next fetch.
/// Only device state is sent (platform, version, UI language), so no AI consent is needed.
public final class LuckgramAnnouncements {
    public static let shared = LuckgramAnnouncements()

    /// Prefix of the chat-list notice ID, so closing it never reaches Telegram's servers.
    public static let noticeIdPrefix = "luckgram:"

    private static let dismissedKey = "announcements_dismissed"

    private var items: [LuckgramAnnouncementLogic.Item] = []
    private var lastSuccess: Date?
    private var lastFailure: Date?
    private var inFlight = false
    private let fetch = MetaDisposable()
    private let currentPromise = ValuePromise<LuckgramAnnouncementLogic.Item?>(nil, ignoreRepeated: true)
    private var expiryTimer: SwiftSignalKit.Timer?

    private init() {
    }

    /// The banner to show (nil = none); updates on fetch, close, end time and logout.
    public var current: Signal<LuckgramAnnouncementLogic.Item?, NoError> {
        return self.currentPromise.get()
    }

    private var dismissed: [String] {
        return LuckgramAnnouncementLogic.parseDismissed(LuckgramSettings.shared.string(LuckgramAnnouncements.dismissedKey, default: nil))
    }

    /// Main queue.
    private func publish() {
        let now = Date()
        let item = LuckgramAnnouncementLogic.pick(self.items, dismissed: self.dismissed, now: now)
        self.currentPromise.set(item)
        self.expiryTimer?.invalidate()
        self.expiryTimer = nil
        if let end = item?.endsAt, end > now {
            let timer = SwiftSignalKit.Timer(timeout: end.timeIntervalSince(now) + 1.0, repeat: false, completion: { [weak self] in
                self?.publish()
            }, queue: .mainQueue())
            self.expiryTimer = timer
            timer.start()
        }
    }

    /// Main queue.
    public func refreshIfStale() {
        if self.inFlight || !LuckgramAnnouncementLogic.shouldRefresh(now: Date(), lastSuccess: self.lastSuccess, lastFailure: self.lastFailure) {
            return
        }
        if !LuckgramSettings.shared.remoteConfig.bool("announcements.enabled", default: true) {
            self.items = []
            self.publish()
            return
        }
        self.inFlight = true
        let lang = LuckgramStrings.isChinese ? "zh-Hans" : "en"
        self.fetch.set(LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/announcements?lang=\(lang)").start(next: { [weak self] response in
            guard let self else {
                return
            }
            self.inFlight = false
            self.lastSuccess = Date()
            self.lastFailure = nil
            self.items = LuckgramAnnouncementLogic.parse(response)
            self.publish()
        }, error: { [weak self] _ in
            self?.inFlight = false
            self?.lastFailure = Date()
        }))
    }

    /// The user closed the notice: never show this announcement again on this device.
    public func dismiss(noticeId: String) {
        guard noticeId.hasPrefix(LuckgramAnnouncements.noticeIdPrefix) else {
            return
        }
        let id = String(noticeId.dropFirst(LuckgramAnnouncements.noticeIdPrefix.count))
        Queue.mainQueue().async {
            LuckgramSettings.shared.setString(LuckgramAnnouncements.dismissedKey, LuckgramAnnouncementLogic.serializeDismissed(LuckgramAnnouncementLogic.dismiss(self.dismissed, id)))
            self.publish()
        }
    }

    /// The last account logged out (LuckgramSettings.accountRemoved): forget everything.
    func clear() {
        Queue.mainQueue().async {
            self.items = []
            self.lastSuccess = nil
            self.publish()
        }
    }
}
