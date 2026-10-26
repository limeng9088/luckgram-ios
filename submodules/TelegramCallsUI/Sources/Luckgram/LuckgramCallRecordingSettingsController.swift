import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

private final class LuckgramCallRecordingSettingsArguments {
    let toggleEnabled: (Bool) -> Void
    let toggleAuto: (Bool) -> Void
    let toggleAi: (Bool) -> Void
    let chooseTarget: () -> Void
    let resetTarget: () -> Void
    
    init(toggleEnabled: @escaping (Bool) -> Void, toggleAuto: @escaping (Bool) -> Void, toggleAi: @escaping (Bool) -> Void, chooseTarget: @escaping () -> Void, resetTarget: @escaping () -> Void) {
        self.toggleEnabled = toggleEnabled
        self.toggleAuto = toggleAuto
        self.toggleAi = toggleAi
        self.chooseTarget = chooseTarget
        self.resetTarget = resetTarget
    }
}

private enum LuckgramCallRecordingSettingsSection: Int32 {
    case main
    case auto
    case ai
    case target
}

private enum LuckgramCallRecordingSettingsEntry: ItemListNodeEntry {
    case enabled(Bool)
    case enabledInfo
    case auto(Bool)
    case autoInfo
    case ai(Bool)
    case aiInfo
    case targetHeader
    case target(String)
    case targetReset
    case targetInfo
    
    var section: ItemListSectionId {
        switch self {
        case .enabled, .enabledInfo:
            return LuckgramCallRecordingSettingsSection.main.rawValue
        case .auto, .autoInfo:
            return LuckgramCallRecordingSettingsSection.auto.rawValue
        case .ai, .aiInfo:
            return LuckgramCallRecordingSettingsSection.ai.rawValue
        case .targetHeader, .target, .targetReset, .targetInfo:
            return LuckgramCallRecordingSettingsSection.target.rawValue
        }
    }
    
    var stableId: Int32 {
        switch self {
        case .enabled: return 0
        case .enabledInfo: return 1
        case .auto: return 2
        case .autoInfo: return 3
        case .ai: return 4
        case .aiInfo: return 5
        case .targetHeader: return 6
        case .target: return 7
        case .targetReset: return 8
        case .targetInfo: return 9
        }
    }
    
    static func <(lhs: LuckgramCallRecordingSettingsEntry, rhs: LuckgramCallRecordingSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramCallRecordingSettingsArguments
        typealias S = LuckgramCallRecordingStrings
        switch self {
        case let .enabled(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: S.enable, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleEnabled(value)
            })
        case .enabledInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain(S.enableInfo + "\n\n" + S.legalText), sectionId: self.section)
        case let .auto(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: S.autoRecord, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleAuto(value)
            })
        case .autoInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain(S.autoRecordInfo), sectionId: self.section)
        case let .ai(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: S.aiTranscript, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleAi(value)
            })
        case .aiInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain(S.aiTranscriptInfo), sectionId: self.section)
        case .targetHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: S.saveTo.uppercased(), sectionId: self.section)
        case let .target(name):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: S.chooseChat, label: name, sectionId: self.section, style: .blocks, action: {
                arguments.chooseTarget()
            })
        case .targetReset:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: S.resetToSaved, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.resetTarget()
            })
        case .targetInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain(S.saveToInfo), sectionId: self.section)
        }
    }
}

private struct LuckgramCallRecordingSettingsState: Equatable {
    var enabled: Bool
    var auto: Bool
    var ai: Bool
    var targetPeerId: EnginePeer.Id?
}

private func luckgramCallRecordingSettingsEntries(state: LuckgramCallRecordingSettingsState, targetName: String) -> [LuckgramCallRecordingSettingsEntry] {
    var entries: [LuckgramCallRecordingSettingsEntry] = []
    entries.append(.enabled(state.enabled))
    entries.append(.enabledInfo)
    if state.enabled {
        entries.append(.auto(state.auto))
        entries.append(.autoInfo)
        entries.append(.ai(state.ai))
        entries.append(.aiInfo)
        entries.append(.targetHeader)
        entries.append(.target(targetName))
        if state.targetPeerId != nil {
            entries.append(.targetReset)
        }
        entries.append(.targetInfo)
    }
    return entries
}

/// Shows the legal reminder (spec 04 §1) and turns call recording on only after "我知道了".
/// Also the hook for the generic switch on the Luckgram features page.
public func luckgramRequestEnableCallRecording(context: AccountContext, present: @escaping (ViewController) -> Void, completion: @escaping (Bool) -> Void) {
    if LuckgramCallRecordingSettings.isEnabled {
        completion(true)
        return
    }
    typealias S = LuckgramCallRecordingStrings
    let alert = textAlertController(context: context, title: S.legalTitle, text: S.legalText, actions: [
        TextAlertAction(type: .genericAction, title: S.cancel, action: {
            completion(false)
        }),
        TextAlertAction(type: .defaultAction, title: S.gotIt, action: {
            LuckgramCallRecordingSettings.isEnabled = true
            completion(true)
            // The transcript is made after the call, when no dialog can be shown, so the shared
            // AI consent (spec 00 §18) is asked for now. Declining turns the AI transcript off.
            if LuckgramCallRecordingSettings.isAiTranscriptEnabled, let ai = LuckgramCallRecordingAIRegistry.instance, !ai.hasConsent {
                ai.requestConsent(context: context, completion: { agreed in
                    if !agreed {
                        LuckgramCallRecordingSettings.isAiTranscriptEnabled = false
                    }
                })
            }
        })
    ], dismissOnOutsideTap: false)
    present(alert)
}

/// Settings → Luckgram features → Call Recording.
public func luckgramCallRecordingSettingsController(context: AccountContext) -> ViewController {
    let account = context.account
    let readState: () -> LuckgramCallRecordingSettingsState = {
        return LuckgramCallRecordingSettingsState(
            enabled: LuckgramCallRecordingSettings.isEnabled,
            auto: LuckgramCallRecordingSettings.isAutoRecord,
            ai: LuckgramCallRecordingSettings.isAiTranscriptEnabled,
            targetPeerId: LuckgramCallRecordingSettings.targetPeerId(account: account)
        )
    }
    let statePromise = ValuePromise(readState(), ignoreRepeated: true)
    let refresh: () -> Void = {
        statePromise.set(readState())
    }
    
    var presentControllerImpl: ((ViewController) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    
    let arguments = LuckgramCallRecordingSettingsArguments(toggleEnabled: { value in
        if value {
            luckgramRequestEnableCallRecording(context: context, present: { controller in
                presentControllerImpl?(controller)
            }, completion: { _ in
                refresh()
            })
            // Keep the switch off until the reminder is acknowledged.
            refresh()
        } else {
            LuckgramCallRecordingSettings.isEnabled = false
            refresh()
        }
    }, toggleAuto: { value in
        LuckgramCallRecordingSettings.isAutoRecord = value
        refresh()
    }, toggleAi: { value in
        LuckgramCallRecordingSettings.isAiTranscriptEnabled = value
        refresh()
        if value, let ai = LuckgramCallRecordingAIRegistry.instance, !ai.hasConsent {
            ai.requestConsent(context: context, completion: { agreed in
                if !agreed {
                    LuckgramCallRecordingSettings.isAiTranscriptEnabled = false
                    refresh()
                }
            })
        }
    }, chooseTarget: {
        let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeDisabled], hasContactSelector: false, hasGlobalSearch: false))
        controller.peerSelected = { [weak controller] peer, _ in
            LuckgramCallRecordingSettings.setTargetPeerId(account: account, peerId: peer.id)
            refresh()
            controller?.dismiss()
        }
        pushControllerImpl?(controller)
    }, resetTarget: {
        LuckgramCallRecordingSettings.setTargetPeerId(account: account, peerId: nil)
        refresh()
    })
    
    let targetName: (LuckgramCallRecordingSettingsState) -> Signal<String, NoError> = { state in
        guard let targetPeerId = state.targetPeerId else {
            return .single(LuckgramCallRecordingStrings.savedMessages)
        }
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: targetPeerId))
        |> map { peer -> String in
            guard let peer else {
                return LuckgramCallRecordingStrings.savedMessages
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            return peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        }
    }
    
    let stateWithTarget = statePromise.get()
    |> mapToSignal { state -> Signal<(LuckgramCallRecordingSettingsState, String), NoError> in
        return targetName(state) |> map { name in (state, name) }
    }
    
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, stateWithTarget)
    |> map { presentationData, stateAndName -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let (state, name) = stateAndName
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramCallRecordingStrings.featureName), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luckgramCallRecordingSettingsEntries(state: state, targetName: name), style: .blocks, emptyStateItem: nil, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}
