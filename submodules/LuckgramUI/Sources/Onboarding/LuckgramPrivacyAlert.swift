import Foundation
import UIKit
import Display
import AccountContext
import PresentationDataUtils

/// specs#78: the Luckgram privacy policy alert. Shown on the welcome page until the user taps
/// Continue, and to logged-in users once more when `app.privacy_version` is raised ("privacy
/// policy updated"). No dismiss on outside tap; "Privacy Policy" opens the page and shows the alert
/// again so it is still there on return. Continue stores the agreement with its time and version.
public enum LuckgramPrivacyAlert {
    public static var isAccepted: Bool {
        return LuckgramSettings.shared.bool(LuckgramWelcomeLogic.acceptedKey, default: false)
    }

    private static var remoteVersion: Int {
        return LuckgramSettings.shared.remoteConfig.int(LuckgramWelcomeLogic.privacyVersionKey, default: 0)
    }

    private static func accept() {
        LuckgramSettings.shared.setBool(LuckgramWelcomeLogic.acceptedKey, true)
        LuckgramSettings.shared.setString(LuckgramWelcomeLogic.acceptedAtKey, "\(Int64(Date().timeIntervalSince1970 * 1000.0))")
        LuckgramSettings.shared.setInt(LuckgramWelcomeLogic.acceptedVersionKey, LuckgramPrivacyAlert.remoteVersion)
    }

    /// Presents the alert with `present`; `onAccepted` runs after Continue.
    public static func show(sharedContext: SharedAccountContext, updated: Bool, openUrl: @escaping (String) -> Void, present: @escaping (ViewController) -> Void, onAccepted: (() -> Void)?) {
        let texts = LuckgramWelcomeLogic.Texts(zh: LuckgramStrings.isChinese)
        let alert = textAlertController(sharedContext: sharedContext, title: updated ? texts.privacyUpdatedTitle : texts.privacyTitle, text: updated ? texts.privacyUpdatedText : texts.privacyText, actions: [
            TextAlertAction(type: .genericAction, title: texts.privacyPolicyButton, action: {
                openUrl(LuckgramWelcomeLogic.privacyURL(LuckgramSettings.shared.remoteConfig.string(LuckgramWelcomeLogic.privacyURLKey, default: nil), zh: LuckgramStrings.isChinese))
                LuckgramPrivacyAlert.show(sharedContext: sharedContext, updated: updated, openUrl: openUrl, present: present, onAccepted: onAccepted)
            }),
            TextAlertAction(type: .defaultAction, title: texts.continueButton, action: {
                LuckgramPrivacyAlert.accept()
                onAccepted?()
            })
        ], dismissOnOutsideTap: false)
        present(alert)
    }

    private static var checkedThisRun = false

    /// At launch with an account logged in: "privacy policy updated" once if the version went up.
    public static func checkUpdate(context: AccountContext, present: @escaping (ViewController) -> Void) {
        if LuckgramPrivacyAlert.checkedThisRun {
            return
        }
        LuckgramPrivacyAlert.checkedThisRun = true
        let accepted = LuckgramSettings.shared.int(LuckgramWelcomeLogic.acceptedVersionKey, default: 0)
        guard LuckgramWelcomeLogic.shouldPromptUpdate(loggedIn: true, remoteVersion: LuckgramPrivacyAlert.remoteVersion, acceptedVersion: accepted) else {
            return
        }
        let sharedContext = context.sharedContext
        LuckgramPrivacyAlert.show(sharedContext: sharedContext, updated: true, openUrl: { url in
            sharedContext.applicationBindings.openUrl(url)
        }, present: present, onAccepted: nil)
    }
}
