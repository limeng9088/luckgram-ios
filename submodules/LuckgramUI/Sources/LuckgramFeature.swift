import Foundation
import Display
import AccountContext

/// One entry of the Luckgram feature registry (`LuckgramFeatures`). The settings page is generated from these.
public final class LuckgramFeature {
    /// Settings page groups, in display order.
    public enum Group: Int, CaseIterable {
        case accountPrivacy
        case messagesLanguage
        case mediaCallsStorage
        case profileOrganize
        case ai
        /// Only shown when `LuckgramSettings.shared.isDebugToolsVisible`.
        case debug
    }

    public let key: String
    public let group: Group
    public let defaultValue: Bool
    let titleZh: String
    let titleEn: String
    let descriptionZh: String
    let descriptionEn: String
    /// Builds the feature's own settings page, or nil if it has none.
    public private(set) var subpageBuilder: ((AccountContext) -> ViewController)?
    public private(set) var isDebugOnly: Bool = false
    /// Optional check before the switch goes from off to on (e.g. a legal notice), issue #58.
    /// Call `done(true)` to switch it on, `done(false)` to leave it off. Not called when switching off.
    public private(set) var confirmEnableHandler: ((AccountContext, @escaping (ViewController) -> Void, @escaping (Bool) -> Void) -> Void)?

    private init(key: String, group: Group, defaultValue: Bool, titleZh: String, titleEn: String, descriptionZh: String, descriptionEn: String) {
        self.key = key
        self.group = group
        self.defaultValue = defaultValue
        self.titleZh = titleZh
        self.titleEn = titleEn
        self.descriptionZh = descriptionZh
        self.descriptionEn = descriptionEn
    }

    /// - Parameters:
    ///   - key: storage key (same on Android), snake_case
    ///   - defaultValue: default switch state, as written in the feature's spec
    public static func toggle(_ key: String, group: Group, default defaultValue: Bool, title: (zh: String, en: String), description: (zh: String, en: String)) -> LuckgramFeature {
        return LuckgramFeature(key: key, group: group, defaultValue: defaultValue, titleZh: title.zh, titleEn: title.en, descriptionZh: description.zh, descriptionEn: description.en)
    }

    @discardableResult
    public func subpage(_ subpage: @escaping (AccountContext) -> ViewController) -> LuckgramFeature {
        self.subpageBuilder = subpage
        return self
    }

    @discardableResult
    public func confirmEnable(_ handler: @escaping (_ context: AccountContext, _ present: @escaping (ViewController) -> Void, _ done: @escaping (Bool) -> Void) -> Void) -> LuckgramFeature {
        self.confirmEnableHandler = handler
        return self
    }

    @discardableResult
    public func debugOnly(_ value: Bool = true) -> LuckgramFeature {
        self.isDebugOnly = value
        return self
    }

    public var title: String {
        return LuckgramStrings.pick(self.titleZh, self.titleEn)
    }

    public var descriptionText: String {
        return LuckgramStrings.pick(self.descriptionZh, self.descriptionEn)
    }

    public var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(self.key)
    }

    /// The user's switch, as shown on the settings row.
    public var isLocallyEnabled: Bool {
        return LuckgramSettings.shared.isLocallyEnabled(self.key)
    }

    public var isVisible: Bool {
        return (!self.isDebugOnly || LuckgramSettings.shared.isDebugToolsVisible) && LuckgramSettings.shared.isRemotelyAllowed(self.key)
    }
}
