import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import OverlayStatusController

/// specs#108 entry: 「翻译图片」 in the photo menus and the gallery preview, 「译」 on the viewer
/// (through #106's `LuckgramImageActions`). Recognition is #106's `LuckgramOcr` (on-device,
/// cached per image); this only translates and draws. Same as Android `ImageTranslateEntry`.
public enum LuckgramImageTranslateEntry {
    public static let actionId = "image_translate"

    public static func action() -> LuckgramImageActions.Action {
        return LuckgramImageActions.Action(id: actionId, title: ("翻译图片", "Translate image"), icon: "translate", buttonTitle: ("译", "Tr"), places: [.menu, .viewerButton, .attachPreview], isVisible: { _ in
            return LuckgramImageTranslateSettings.isEnabled
        }, run: { target in
            run(target)
        })
    }

    static func run(_ target: LuckgramImageActions.Target) {
        let context = target.context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        let progress = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
        context.sharedContext.mainWindow?.present(progress, on: .root)
        let peerId = target.message.map { $0.id.peerId.toInt64() }
        let replace = target.replaceImage
        let _ = LuckgramOcr.recognize(image: target.image, key: target.imageKey).start(next: { result in
            progress.dismiss()
            let blocks = self.blocks(result)
            if blocks.isEmpty {
                present(context, message: LuckgramImageTranslateStrings.noText)
                return
            }
            let controller = LuckgramImageTranslateController(context: context, image: target.image, blocks: blocks, imageLanguage: result.language, peerId: peerId, sendTranslated: replace)
            context.sharedContext.applicationBindings.presentNativeController(controller)
        }, error: { _ in
            progress.dismiss()
            present(context, message: LuckgramImageTranslateStrings.noText)
        })
    }

    static func blocks(_ result: LuckgramOcrResult) -> [LuckgramImageTranslateRenderer.Block] {
        return result.blocks.compactMap { b in
            if b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            return LuckgramImageTranslateRenderer.Block(x: b.box.x, y: b.box.y, width: b.box.width, height: b.box.height, lineCount: max(1, b.lines.count), original: b.text)
        }
    }

    private static func present(_ context: AccountContext, message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LuckgramStrings.ok, style: .default))
        context.sharedContext.applicationBindings.presentNativeController(alert)
    }
}

// MARK: - Luckgram Features → Translate images

private final class LuckgramImageTranslateSettingsArguments {
    let pick: () -> Void

    init(pick: @escaping () -> Void) {
        self.pick = pick
    }
}

private enum LuckgramImageTranslateSettingsEntry: ItemListNodeEntry {
    case language(String, String)
    case info(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int {
        switch self {
        case .language:
            return 0
        case .info:
            return 1
        }
    }

    static func <(lhs: LuckgramImageTranslateSettingsEntry, rhs: LuckgramImageTranslateSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: LuckgramImageTranslateSettingsEntry, rhs: LuckgramImageTranslateSettingsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.language(a1, a2), .language(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.info(a), .info(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramImageTranslateSettingsArguments
        switch self {
        case let .language(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.pick()
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// The image-only language, or "same as message translation" (specs#108 需求 2). Same rows as Android.
public func luckgramImageTranslateSettingsController(context: AccountContext) -> ViewController {
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    let refresh = {
        version += 1
        updated.set(version)
    }
    let arguments = LuckgramImageTranslateSettingsArguments(pick: {
        let sheet = UIAlertController(title: LuckgramImageTranslateStrings.settingsLanguage, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: LuckgramImageTranslateStrings.followReading, style: .default, handler: { _ in
            LuckgramImageTranslateSettings.followReadingLanguage()
            refresh()
        }))
        sheet.addAction(UIAlertAction(title: LuckgramStrings.pick("选择语言", "Choose language"), style: .default, handler: { _ in
            let _ = LuckgramImageTranslateSettings.pickLanguage(selected: LuckgramImageTranslateSettings.targetLanguage(peerId: nil), completion: { code in
                LuckgramImageTranslateSettings.setLanguage(peerId: nil, lang: code, onlyThisChat: false)
                refresh()
            })
        }))
        sheet.addAction(UIAlertAction(title: LuckgramStrings.cancel, style: .cancel))
        if let view = context.sharedContext.mainWindow?.viewController?.view {
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1.0, height: 1.0)
        }
        context.sharedContext.applicationBindings.presentNativeController(sheet)
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, updated.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        let value = LuckgramImageTranslateSettings.imageDefault.flatMap { LuckgramImageTranslateSettings.languageName($0) } ?? LuckgramImageTranslateStrings.followReading
        let entries: [LuckgramImageTranslateSettingsEntry] = [
            .language(LuckgramImageTranslateStrings.settingsLanguage, value),
            .info(LuckgramImageTranslateStrings.settingsInfo)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramImageTranslateStrings.translateImage), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
