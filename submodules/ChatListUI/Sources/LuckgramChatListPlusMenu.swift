import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ContextUI
import AlertUI
import UndoUI
import DeviceAccess
import QrCodeUI
import LuckgramUI

private let texts = LuckgramScanLogic.Texts(zh: LuckgramStrings.isChinese)

private final class LuckgramPlusMenuReferenceSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds, insets: UIEdgeInsets(top: -4.0, left: 0.0, bottom: -4.0, right: 0.0))
    }
}

/// specs#92: the chat list 「+」 menu: 扫一扫, 代理配置 (with its state).
func luckgramShowChatListPlusMenu(context: AccountContext, controller: ChatListControllerImpl, sourceView: UIView, proxyState: LuckgramScanLogic.ProxyState) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    var items: [ContextMenuItem] = []
    items.append(.action(ContextMenuActionItem(text: texts.scan, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Settings/ScanQr"), color: theme.contextMenu.primaryColor)
    }, action: { [weak controller] c, _ in
        c?.dismiss(completion: {
            guard let controller else {
                return
            }
            luckgramOpenScanner(context: context, controller: controller)
        })
    })))
    items.append(.action(ContextMenuActionItem(text: texts.proxy, textLayout: .secondLineWithValue(texts.proxyState(proxyState)), icon: { theme in
        return generateTintedImage(image: UIImage(systemName: "shield"), color: theme.contextMenu.primaryColor)
    }, action: { [weak controller] c, _ in
        c?.dismiss(completion: {
            (controller?.navigationController as? NavigationController)?.pushViewController(context.sharedContext.makeProxySettingsController(context: context))
        })
    })))
    let contextController = makeContextController(presentationData: presentationData, source: .reference(LuckgramPlusMenuReferenceSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: nil)
    context.sharedContext.mainWindow?.presentInGlobalOverlay(contextController)
}

/// 「扫一扫」: camera permission (denied → Telegram's settings prompt), then Telegram's QR scanner with the
/// album button and 「我的二维码」; the code goes to Telegram's own flow.
private func luckgramOpenScanner(context: AccountContext, controller: ChatListControllerImpl) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    DeviceAccess.authorizeAccess(to: .camera(.qrCode), presentationData: presentationData, present: { c, a in
        c.presentationArguments = a
        context.sharedContext.mainWindow?.present(c, on: .root)
    }, openSettings: {
        context.sharedContext.applicationBindings.openSettings()
    }, { [weak controller] granted in
        guard granted, let controller, let navigationController = controller.navigationController as? NavigationController else {
            return
        }
        let scanner = QrCodeScanScreen(context: context, subject: .luckgram(info: texts.scanHint, myCodeTitle: texts.myQr))
        scanner.showMyCode = { [weak scanner] in
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
            |> deliverOnMainQueue).start(next: { peer in
                guard let peer, let scanner else {
                    return
                }
                scanner.present(context.sharedContext.makeChatQrCodeScreen(context: context, peer: peer, threadId: nil, temporary: false), in: .window(.root))
            })
        }
        scanner.completion = { [weak scanner, weak navigationController] code in
            guard let code else {
                return
            }
            scanner?.dismiss()
            Queue.mainQueue().after(0.3) {
                luckgramHandleScannedCode(context: context, code: code, navigationController: navigationController)
            }
        }
        navigationController.pushViewController(scanner)
    })
}

/// What to do with a scanned code (same rules as Android `LuckgramScan.handle`).
func luckgramHandleScannedCode(context: AccountContext, code: String, navigationController: NavigationController?) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let present: (ViewController) -> Void = { c in
        context.sharedContext.mainWindow?.present(c, on: .root)
    }
    let openUrl: (String) -> Void = { url in
        context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: navigationController, dismissInput: {})
    }
    let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
    switch LuckgramScanLogic.kind(text) {
    case .telegram, .proxy:
        // Telegram's own handling: profile (with Add contact), group, channel, add-proxy sheet
        openUrl(LuckgramScanLogic.url(text))
    case .login:
        guard let token = LuckgramScanLogic.loginToken(text) else {
            present(textAlertController(context: context, title: texts.loginTitle, text: texts.loginFailed, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
            return
        }
        present(textAlertController(context: context, title: texts.loginTitle, text: texts.loginConfirm, actions: [
            TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: texts.login, action: {
                let _ = (approveAuthTransferToken(account: context.account, token: token, activeSessionsContext: context.engine.privacy.activeSessions())
                |> deliverOnMainQueue).start(next: { _ in
                    present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: texts.loginDone, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
                }, error: { _ in
                    present(textAlertController(context: context, title: texts.loginTitle, text: texts.loginFailed, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
                })
            })
        ]))
    case .web:
        let url = LuckgramScanLogic.url(text)
        present(textAlertController(context: context, title: texts.openLink, text: url, actions: [
            TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: texts.open, action: {
                openUrl(url)
            })
        ]))
    case .text:
        present(textAlertController(context: context, title: texts.text, text: text, actions: [
            TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: texts.copy, action: {
                UIPasteboard.general.string = text
                present(UndoOverlayController(presentationData: presentationData, content: .copy(text: texts.copied), elevatedLayout: false, action: { _ in return false }))
            })
        ]))
    }
}
