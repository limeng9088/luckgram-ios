import Foundation
import Display
import SwiftSignalKit
import AccountContext
import PresentationDataUtils
import LuckgramUI

/// Luckgram: the legal reminder must come before call recording is switched on (spec 04 §1),
/// including when the switch is flipped on the "Luckgram features" page, which writes the value
/// directly (limeng9088/luckgram-specs#58).
///
/// Switched on without acknowledgement -> show the reminder; "我知道了" acknowledges it, "取消"
/// switches it back off. Until acknowledged `LuckgramCallRecordingSettings.isEnabled` stays false,
/// so no record button can appear in between. Same behaviour as Android's CallRecLegalGuard.
private final class LuckgramCallRecordingLegalGuard {
    static var installed: LuckgramCallRecordingLegalGuard?
    
    private weak var sharedContext: SharedAccountContext?
    private var disposable: Disposable?
    private var isShowing = false
    
    init(sharedContext: SharedAccountContext) {
        self.sharedContext = sharedContext
        // A switch left on without acknowledgement (app killed while the reminder was up) is off.
        if LuckgramCallRecordingSettings.isSwitchOn && !LuckgramCallRecordingSettings.isLegalAcknowledged {
            LuckgramSettings.shared.setEnabled(LuckgramCallRecordingSettings.enabledKey, false)
        }
        self.disposable = (LuckgramSettings.shared.changes
        |> filter { key in key == nil || key == LuckgramCallRecordingSettings.enabledKey }
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.check()
        })
    }
    
    private func check() {
        let typedSettings = LuckgramCallRecordingSettings.self
        if !typedSettings.isSwitchOn {
            if typedSettings.isLegalAcknowledged {
                LuckgramSettings.shared.setBool(typedSettings.legalAckKey, false)
            }
            return
        }
        if typedSettings.isLegalAcknowledged || self.isShowing {
            return
        }
        guard let sharedContext = self.sharedContext, let mainWindow = sharedContext.mainWindow else {
            LuckgramSettings.shared.setEnabled(typedSettings.enabledKey, false)
            return
        }
        self.isShowing = true
        typealias S = LuckgramCallRecordingStrings
        let alert = textAlertController(sharedContext: sharedContext, title: S.legalTitle, text: S.legalText, actions: [
            TextAlertAction(type: .genericAction, title: S.cancel, action: { [weak self] in
                self?.isShowing = false
                LuckgramSettings.shared.setEnabled(typedSettings.enabledKey, false)
            }),
            TextAlertAction(type: .defaultAction, title: S.gotIt, action: { [weak self] in
                self?.isShowing = false
                typedSettings.isEnabled = true
                // Same as the settings page: ask the AI consent now, it can't be asked after a call.
                guard typedSettings.isAiTranscriptEnabled, let ai = LuckgramCallRecordingAIRegistry.instance, !ai.hasConsent else {
                    return
                }
                let _ = (sharedContext.activeAccountContexts |> take(1) |> deliverOnMainQueue).start(next: { primary, _, _ in
                    guard let context = primary else {
                        return
                    }
                    ai.requestConsent(context: context, completion: { agreed in
                        if !agreed {
                            typedSettings.isAiTranscriptEnabled = false
                        }
                    })
                })
            })
        ], dismissOnOutsideTap: false)
        mainWindow.present(alert, on: .root, blockInteraction: false, completion: {})
    }
}

/// Hook: SharedAccountContext init.
public func luckgramInstallCallRecordingLegalGuard(sharedContext: SharedAccountContext) {
    if LuckgramCallRecordingLegalGuard.installed == nil {
        LuckgramCallRecordingLegalGuard.installed = LuckgramCallRecordingLegalGuard(sharedContext: sharedContext)
    }
}
