import Foundation
import UIKit
import CoreLocation
import UserNotifications
import SwiftSignalKit
import LuckgramDiscover

/// Device-wide state of "Visible nearby" (spec 25): expiry, the 1-hour reminder and the cleanup
/// on logout / unlink. Same rules as `NearbyController` on Android. Nothing is sent while the
/// `nearby` switch is off.
public enum LuckgramNearby {
    private static let expiresKey = "nearby.expires_at"
    private static let introKey = "nearby.intro_done"
    private static let bioKey = "nearby.bio"
    private static let photoKey = "nearby.show_photo"
    private static let accountKey = "nearby.account"
    static let reminderId = "luckgram.nearby.reminder"

    public static var isFeatureEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(NearbyLogic.featureKey)
    }

    public static var expiresAt: Date? {
        guard let s = LuckgramSettings.shared.string(expiresKey, default: nil), let t = TimeInterval(s), t > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: t)
    }

    public static var isVisible: Bool {
        return !NearbyLogic.isExpired(expiresAt, now: Date())
    }

    static var introDone: Bool {
        get { LuckgramSettings.shared.bool(introKey, default: false) }
        set { LuckgramSettings.shared.setBool(introKey, newValue) }
    }

    static var bio: String {
        get { LuckgramSettings.shared.string(bioKey, default: nil) ?? "" }
        set { LuckgramSettings.shared.setString(bioKey, NearbyLogic.cleanBio(newValue)) }
    }

    static var showPhoto: Bool {
        get { LuckgramSettings.shared.bool(photoKey, default: true) }
        set { LuckgramSettings.shared.setBool(photoKey, newValue) }
    }

    /// Server state from `PUT` or `GET /v1/nearby/me`. `accountId` nil = keep the stored one.
    static func apply(_ s: NearbyLogic.MyState, accountId: Int64?) {
        if s.visible, let e = s.expiresAt, e > Date() {
            LuckgramSettings.shared.setString(expiresKey, String(e.timeIntervalSince1970))
            if let accountId {
                LuckgramSettings.shared.setString(accountKey, String(accountId))
            }
            scheduleReminder(expiresAt: e)
        } else {
            clearLocal()
        }
    }

    static func clearLocal() {
        LuckgramSettings.shared.remove(expiresKey)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderId])
        center.removeDeliveredNotifications(withIdentifiers: [reminderId])
    }

    static func turnOff() -> Signal<[String: Any], LuckgramAIError> {
        clearLocal()
        return LuckgramAI.shared.requestJSON(method: "DELETE", path: "/v1/nearby/me")
    }

    /// An account was logged out / removed (called before the device token is reset): delete the
    /// card now if it carries this account's username.
    public static func onLogout(accountId: Int64) {
        LuckgramBlocks.clearLocal()
        guard isVisible else {
            return
        }
        if let stored = LuckgramSettings.shared.string(accountKey, default: nil), stored != String(accountId) {
            return
        }
        clearLocal()
        LuckgramAI.shared.sendWithCurrentToken(method: "DELETE", path: "/v1/nearby/me")
    }

    /// S6 unlink: the server deletes the card itself; only forget it here.
    public static func onUnlinked() {
        LuckgramBlocks.clearLocal()
        clearLocal()
    }

    static func onError(_ error: LuckgramAIError) {
        if error.code == "not_linked" || error.code == "banned" {
            clearLocal()
        }
    }

    private static func scheduleReminder(expiresAt: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderId])
        guard let at = NearbyLogic.reminderAt(expiresAt: expiresAt, now: Date()) else {
            return
        }
        let tx = NearbyLogic.Texts(zh: LuckgramStrings.isChinese)
        let content = UNMutableNotificationContent()
        content.title = tx.reminderTitle
        content.body = tx.reminderText
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: reminderId, content: content, trigger: trigger), withCompletionHandler: nil)
    }
}

/// One-shot "when in use" location (spec 25 item 5): `requestLocation()` only, never continuous
/// updates or background location. Delivers a coordinate or nil on the main queue.
final class LuckgramNearbyLocator: NSObject, CLLocationManagerDelegate {
    enum Result {
        case location(CLLocationCoordinate2D)
        case denied
        case servicesOff
        case failed
    }

    private let manager = CLLocationManager()
    private var completion: ((Result) -> Void)?
    private var waitingForAuthorization = false

    override init() {
        super.init()
        self.manager.delegate = self
        // ~1 km is all we use; lower accuracy is faster and needs no precise permission.
        self.manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    static var isDenied: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .denied || status == .restricted
    }

    static var isAuthorized: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func request(_ completion: @escaping (Result) -> Void) {
        self.completion = completion
        if !CLLocationManager.locationServicesEnabled() {
            self.finish(.servicesOff)
            return
        }
        switch self.manager.authorizationStatus {
        case .notDetermined:
            self.waitingForAuthorization = true
            self.manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            self.finish(.denied)
        default:
            self.manager.requestLocation()
        }
    }

    func cancel() {
        self.completion = nil
        self.manager.stopUpdatingLocation()
    }

    private func finish(_ result: Result) {
        let completion = self.completion
        self.completion = nil
        Queue.mainQueue().async {
            completion?(result)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard self.waitingForAuthorization else {
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            return
        case .denied, .restricted:
            self.waitingForAuthorization = false
            self.finish(.denied)
        default:
            self.waitingForAuthorization = false
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let c = locations.last?.coordinate, self.completion != nil {
            self.finish(.location(c))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if self.completion != nil {
            self.finish(.failed)
        }
    }
}
