import Foundation
import Display
import AccountContext
import UndoUI

/// Luckgram: short toast for call recording events (same messages as Android's toasts).
func luckgramCallRecordingToast(context: AccountContext, text: String) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let controller = UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return true })
    context.sharedContext.mainWindow?.present(controller, on: .root, blockInteraction: false, completion: {})
}
