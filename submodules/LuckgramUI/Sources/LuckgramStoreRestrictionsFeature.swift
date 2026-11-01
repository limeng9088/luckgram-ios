import Foundation
import Display
import AccountContext
import TelegramCore
import PresentationDataUtils

/// Luckgram spec 13 (受限频道): switch key, explanation before enabling, and keeping TelegramCore's
/// `LuckgramStoreRestrictions.isEnabled` in sync with `LuckgramSettings`.
public enum LuckgramStoreRestrictionsFeature {
    public static let key = "store_restrictions_off"

    /// Copies the switch into TelegramCore; call at startup and on every settings change.
    public static func sync() {
        LuckgramStoreRestrictions.isEnabled = LuckgramSettings.shared.isEnabled(key)
    }

    static func confirmEnable(context: AccountContext, present: @escaping (ViewController) -> Void, done: @escaping (Bool) -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let alert = textAlertController(
            context: context,
            title: LuckgramStrings.pick("受限频道", "Store-restricted channels"),
            text: LuckgramStrings.pick(
                "打开后，仅在商店版 Telegram 中被隐藏的频道和群组可以查看。Telegram 对所有平台封禁的内容，以及你所在地区依法屏蔽的内容，仍然无法查看。",
                "When on, channels and groups that are hidden only in the App Store / Google Play versions of Telegram can be viewed. Content Telegram blocks on all platforms, and content blocked by law in your region, stays unavailable."
            ),
            actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
                    done(false)
                }),
                TextAlertAction(type: .defaultAction, title: LuckgramStrings.pick("打开", "Turn On"), action: {
                    done(true)
                })
            ],
            dismissOnOutsideTap: false // the switch stays off unless "Turn On" is chosen
        )
        present(alert)
    }
}
