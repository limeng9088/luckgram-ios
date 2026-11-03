// Luckgram spec 01 A.3/A.4: settings of received-message translation (secondary page of the
// translate_in switch in Settings → Luckgram features → Messages & Language). Same items as
// Android `TranslateInSettingsActivity`: 「翻译成」 (default the app language) and 「不翻译的语言」
// (Telegram's "Do not translate" list).

import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import Display
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import SettingsUI
import ChatTextInputPanelNode
import LuckgramUI

private final class LuckgramTranslateInSettingsArguments {
    let openTarget: () -> Void
    let openDoNotTranslate: () -> Void

    init(openTarget: @escaping () -> Void, openDoNotTranslate: @escaping () -> Void) {
        self.openTarget = openTarget
        self.openDoNotTranslate = openDoNotTranslate
    }
}

private enum LuckgramTranslateInSettingsEntry: ItemListNodeEntry {
    case target(String, String)
    case doNotTranslate(String, String)
    case info(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .target:
            return 0
        case .doNotTranslate:
            return 1
        case .info:
            return 2
        }
    }

    static func <(lhs: LuckgramTranslateInSettingsEntry, rhs: LuckgramTranslateInSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramTranslateInSettingsArguments
        switch self {
        case let .target(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openTarget()
            })
        case let .doNotTranslate(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openDoNotTranslate()
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func luckgramLanguageName(_ code: String?) -> String {
    guard let base = LuckgramTranslateInLogic.base(code) else {
        return ""
    }
    let locale = Locale(identifier: LuckgramStrings.isChinese ? "zh-Hans" : "en")
    return locale.localizedString(forLanguageCode: base) ?? base
}

func luckgramTranslateInSettingsController(context: AccountContext) -> ViewController {
    let s: (String, String) -> String = { zh, en in LuckgramStrings.isChinese ? zh : en }
    let targetUpdated = ValuePromise<Int>(0, ignoreRepeated: false)
    var pushImpl: ((ViewController) -> Void)?

    let arguments = LuckgramTranslateInSettingsArguments(openTarget: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let picker = LuckgramTranslateOut.makeLanguagePicker(strings: presentationData.strings, isDark: presentationData.theme.overallDarkAppearance, selected: LuckgramTranslateInLogic.base(LuckgramTranslateInController.targetLanguage), completion: { code in
            LuckgramSettings.shared.setString(LuckgramTranslateInController.toLangKey, code)
            targetUpdated.set(0)
        })
        context.sharedContext.mainWindow?.presentNative(picker)
    }, openDoNotTranslate: {
        pushImpl?(translationSettingsController(context: context))
    })

    let sharedData = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.translationSettings])
    let signal = combineLatest(queue: Queue.mainQueue(), context.sharedContext.presentationData, sharedData, targetUpdated.get())
    |> map { presentationData, sharedData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.translationSettings]?.get(TranslationSettings.self) ?? TranslationSettings.defaultSettings
        let excluded = settings.ignoredLanguages ?? [presentationData.strings.baseLanguageCode]
        let excludedNames = excluded.map { luckgramLanguageName($0) }.filter { !$0.isEmpty }.joined(separator: LuckgramStrings.isChinese ? "、" : ", ")
        let entries: [LuckgramTranslateInSettingsEntry] = [
            .target(s("翻译成", "Translate to"), LuckgramTranslateInController.targetLanguage.flatMap { luckgramLanguageName($0) } ?? s("未选择（第一次翻译时选）", "Not set (asked the first time)")),
            .doNotTranslate(s("不翻译的语言", "Do not translate"), excludedNames),
            .info(s("长按消息选「翻译」，或点消息旁的翻译图标，译文显示在原文下方。「不翻译的语言」的消息不显示翻译图标，长按仍可翻译。", "Long-press a message and choose Translate, or tap the translate icon next to it; the translation appears below the original. Messages in a \"do not translate\" language get no icon but can still be translated from the menu."))
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(s("收到消息翻译", "Translate received messages")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}
