import Foundation
import SwiftSignalKit
import LuckgramDiscover

/// luckgram-specs#115: sends Square behavior events (`SquareEvents`) in batches — every 30 s or 20
/// events, and when a Square page goes away. Failures are silent (retry once, then dropped). The
/// queue stays on the device until sent. Main thread only. Same as Android `SquareEventReporter`.
enum LuckgramSquareEvents {
    private static let queueKey = "square_events_queue"
    private static var queueStore: SquareEvents.Queue?
    private static var sending = false
    private static var timer: Foundation.Timer?

    private static var queue: SquareEvents.Queue {
        if let q = self.queueStore {
            return q
        }
        let q = SquareEvents.Queue(stored: LuckgramSettings.shared.string(self.queueKey, default: nil), now: SquareEvents.nowMs())
        self.queueStore = q
        return q
    }

    private static func save() {
        LuckgramSettings.shared.setString(self.queueKey, self.queue.encoded())
    }

    static func add(_ events: [SquareEvents.Event]) {
        if events.isEmpty || !LuckgramSquare.isFeatureEnabled {
            return
        }
        self.queue.add(events)
        self.save()
        self.flush(force: false)
    }

    static func add(type: String, postId: String, tab: String, rank: Int = -1) {
        self.add([SquareEvents.Event(type: type, postId: postId, tab: tab, rank: rank, timeMs: SquareEvents.nowMs())])
    }

    private static func schedule() {
        self.timer?.invalidate()
        self.timer = Foundation.Timer.scheduledTimer(withTimeInterval: TimeInterval(SquareEvents.flushIntervalMs) / 1000.0, repeats: false) { _ in
            LuckgramSquareEvents.flush(force: false)
        }
    }

    /// `force`: leaving the page / going to the background.
    static func flush(force: Bool) {
        self.timer?.invalidate()
        self.timer = nil
        let q = self.queue
        if q.count == 0 {
            return
        }
        if self.sending || !(force || q.shouldFlush(now: SquareEvents.nowMs())) {
            self.schedule()
            return
        }
        guard let batch = q.nextBatch() else {
            return
        }
        self.sending = true
        let _ = (LuckgramAI.shared.requestJSON(method: "POST", path: SquareEvents.path, body: batch.body)
        |> deliverOnMainQueue).startStandalone(next: { _ in
            self.sending = false
            self.queue.onSent(count: batch.count, now: SquareEvents.nowMs())
            self.save()
            if self.queue.count > 0 {
                self.schedule()
            }
        }, error: { error in
            self.sending = false
            self.queue.onFailed(count: batch.count, httpStatus: error.httpStatus, now: SquareEvents.nowMs())
            self.save()
            if self.queue.count > 0 {
                self.schedule()
            }
        })
    }
}
