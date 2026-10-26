import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

/// Paper-plane icon on a blue gradient tile for the Settings row (same style as Telegram's 30×30 settings icons).
public enum LuckgramIcons {
    public static let settings: UIImage? = generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        let bounds = CGRect(origin: .zero, size: size)
        context.clear(bounds)
        context.addPath(UIBezierPath(roundedRect: bounds, cornerRadius: 8.0).cgPath)
        context.clip()
        let colors = [UIColor(rgb: 0x2AABEE).cgColor, UIColor(rgb: 0x1C8ADB).cgColor] as CFArray
        var locations: [CGFloat] = [0.0, 1.0]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: &locations) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: [])
        }
        // Plane drawn in a 24×24 box centred in the tile (same outline as the Android vector).
        let scale: CGFloat = 0.85
        let offset = CGPoint(x: (size.width - 24.0 * scale) / 2.0, y: (size.height - 24.0 * scale) / 2.0)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            return CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
        }
        let path = UIBezierPath()
        path.move(to: p(3.4, 11.1))
        path.addLine(to: p(19.6, 4.6))
        path.addCurve(to: p(20.9, 5.8), controlPoint1: p(20.4, 4.3), controlPoint2: p(21.1, 5.0))
        path.addLine(to: p(18.1, 18.9))
        path.addCurve(to: p(16.2, 19.6), controlPoint1: p(17.9, 19.8), controlPoint2: p(16.9, 20.2))
        path.addLine(to: p(12.3, 16.6))
        path.addLine(to: p(10.2, 18.6))
        path.addCurve(to: p(9.1, 18.2), controlPoint1: p(9.8, 19.0), controlPoint2: p(9.2, 18.8))
        path.addLine(to: p(8.6, 15.1))
        path.addLine(to: p(16.4, 8.1))
        path.addCurve(to: p(16.1, 7.8), controlPoint1: p(16.6, 7.9), controlPoint2: p(16.4, 7.6))
        path.addLine(to: p(7.1, 13.5))
        path.addLine(to: p(3.5, 12.4))
        path.addCurve(to: p(3.4, 11.1), controlPoint1: p(2.8, 12.2), controlPoint2: p(2.8, 11.3))
        path.close()
        context.setFillColor(UIColor.white.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
    })
}

private final class LuckgramSettingsArguments {
    let toggle: (String, Bool) -> Void
    let openSubpage: (String) -> Void
    let consent: () -> Void
    let footerTap: () -> Void
    let setMock: (Bool) -> Void
    let selfTest: () -> Void
    let consentCheck: () -> Void
    let resetToken: () -> Void

    init(toggle: @escaping (String, Bool) -> Void, openSubpage: @escaping (String) -> Void, consent: @escaping () -> Void, footerTap: @escaping () -> Void, setMock: @escaping (Bool) -> Void, selfTest: @escaping () -> Void, consentCheck: @escaping () -> Void, resetToken: @escaping () -> Void) {
        self.toggle = toggle
        self.openSubpage = openSubpage
        self.consent = consent
        self.footerTap = footerTap
        self.setMock = setMock
        self.selfTest = selfTest
        self.consentCheck = consentCheck
        self.resetToken = resetToken
    }
}

private enum LuckgramSettingsEntry: ItemListNodeEntry {
    case header(group: Int, text: String)
    case feature(group: Int, index: Int, key: String, title: String, text: String, value: Bool, hasSubpage: Bool)
    case placeholder(group: Int, text: String)
    case consent(title: String, label: String)
    case consentFooter(String)
    case debugMock(String, Bool)
    case debugAction(index: Int, String)
    case debugInfo(String)
    case footer(String)

    private static let debugSection = Int32(LuckgramFeature.Group.debug.rawValue)
    private static let footerSection: Int32 = 100

    var section: ItemListSectionId {
        switch self {
        case let .header(group, _), let .feature(group, _, _, _, _, _, _), let .placeholder(group, _):
            return Int32(group)
        case .consent, .consentFooter:
            return Int32(LuckgramFeature.Group.ai.rawValue)
        case .debugMock, .debugAction, .debugInfo:
            return LuckgramSettingsEntry.debugSection
        case .footer:
            return LuckgramSettingsEntry.footerSection
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(group, _):
            return Int32(group) * 10000
        case let .feature(group, index, _, _, _, _, _):
            return Int32(group) * 10000 + 10 + Int32(index)
        case let .placeholder(group, _):
            return Int32(group) * 10000 + 9000
        case .consent:
            return Int32(LuckgramFeature.Group.ai.rawValue) * 10000 + 9100
        case .consentFooter:
            return Int32(LuckgramFeature.Group.ai.rawValue) * 10000 + 9200
        case .debugMock:
            return LuckgramSettingsEntry.debugSection * 10000 + 9000
        case let .debugAction(index, _):
            return LuckgramSettingsEntry.debugSection * 10000 + 9100 + Int32(index)
        case .debugInfo:
            return LuckgramSettingsEntry.debugSection * 10000 + 9900
        case .footer:
            return LuckgramSettingsEntry.footerSection * 10000
        }
    }

    static func ==(lhs: LuckgramSettingsEntry, rhs: LuckgramSettingsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a1, a2), .header(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.feature(a1, a2, a3, a4, a5, a6, a7), .feature(b1, b2, b3, b4, b5, b6, b7)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5 && a6 == b6 && a7 == b7
        case let (.placeholder(a1, a2), .placeholder(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.consent(a1, a2), .consent(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.consentFooter(a), .consentFooter(b)):
            return a == b
        case let (.debugMock(a1, a2), .debugMock(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.debugAction(a1, a2), .debugAction(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.debugInfo(a), .debugInfo(b)):
            return a == b
        case let (.footer(a), .footer(b)):
            return a == b
        default:
            return false
        }
    }

    static func <(lhs: LuckgramSettingsEntry, rhs: LuckgramSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramSettingsArguments
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .feature(_, _, key, title, text, value, hasSubpage):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(key, value)
            }, action: hasSubpage ? {
                arguments.openSubpage(key)
            } : nil)
        case let .placeholder(_, text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, enabled: false, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .consent(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.consent()
            })
        case let .consentFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .debugMock(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setMock(value)
            })
        case let .debugAction(index, title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                switch index {
                case 0:
                    arguments.selfTest()
                case 1:
                    arguments.consentCheck()
                default:
                    arguments.resetToken()
                }
            })
        case let .debugInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .footer(text):
            // The version line is a link: tapping it 7 times toggles the debug tools.
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section, linkAction: { _ in
                arguments.footerTap()
            }, textAlignment: .center)
        }
    }
}

private let pageGroups: [LuckgramFeature.Group] = [.accountPrivacy, .messagesLanguage, .mediaCallsStorage, .profileOrganize, .ai]

private func luckgramSettingsEntries() -> [LuckgramSettingsEntry] {
    var entries: [LuckgramSettingsEntry] = []
    let all = LuckgramFeatures.all

    func featureEntries(_ group: LuckgramFeature.Group) -> [LuckgramSettingsEntry] {
        var result: [LuckgramSettingsEntry] = []
        for (index, feature) in all.enumerated() where feature.group == group && feature.isVisible {
            result.append(.feature(group: group.rawValue, index: index, key: feature.key, title: feature.title, text: feature.descriptionText, value: feature.isEnabled, hasSubpage: feature.subpageBuilder != nil))
        }
        return result
    }

    for group in pageGroups {
        entries.append(.header(group: group.rawValue, text: LuckgramStrings.group(group).uppercased()))
        let features = featureEntries(group)
        entries.append(contentsOf: features)
        if group == .ai {
            let granted = LuckgramAI.shared.hasConsent
            entries.append(.consent(title: LuckgramStrings.aiConsentRow, label: granted ? LuckgramStrings.aiConsentAllowed : LuckgramStrings.aiConsentNotAllowed))
            entries.append(.consentFooter(granted ? LuckgramStrings.aiConsentGrantedFooter : LuckgramStrings.aiConsentNotGrantedFooter))
        } else if features.isEmpty {
            entries.append(.placeholder(group: group.rawValue, text: LuckgramStrings.comingSoon))
        }
    }

    if LuckgramSettings.shared.isDebugToolsVisible {
        let debug = LuckgramFeature.Group.debug
        entries.append(.header(group: debug.rawValue, text: LuckgramStrings.group(debug).uppercased()))
        entries.append(contentsOf: featureEntries(debug))
        entries.append(.debugMock(LuckgramStrings.pick("AI 使用本地 mock", "AI: use local mock"), LuckgramAI.shared.isUsingMock))
        entries.append(.debugAction(index: 0, LuckgramStrings.pick("AI 自检：注册、流式对话、转写、额度", "AI self-test: register, stream, transcribe, quota")))
        entries.append(.debugAction(index: 1, LuckgramStrings.pick("AI 自检：拒绝同意时不发请求", "AI self-test: no request without consent")))
        entries.append(.debugAction(index: 2, LuckgramStrings.pick("清除设备令牌", "Clear device token")))
        entries.append(.debugInfo(LuckgramStrings.pick("服务器：", "Server: ") + (LuckgramAI.shared.isUsingMock ? "mock" : LuckgramAI.apiBaseURL)))
    }

    let info = Bundle.main.infoDictionary ?? [:]
    let version = "\((info["CFBundleShortVersionString"] as? String) ?? "") (\((info["CFBundleVersion"] as? String) ?? ""))"
    let footer = LuckgramStrings.footer(version: version)
    let lines = footer.components(separatedBy: "\n")
    let markdown = "[\(lines.first ?? "")](luckgram-version)\n" + lines.dropFirst().joined(separator: "\n")
    entries.append(.footer(markdown))
    return entries
}

/// Settings → Luckgram Features. Generated from `LuckgramFeatures`; adding a feature never requires changes here.
public func luckgramSettingsController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var footerTaps = 0
    var lastFooterTap = 0.0

    let arguments = LuckgramSettingsArguments(
        toggle: { key, value in
            LuckgramSettings.shared.setEnabled(key, value)
        },
        openSubpage: { key in
            if let builder = LuckgramFeatures.find(key)?.subpageBuilder {
                pushImpl?(builder(context))
            }
        },
        consent: {
            if LuckgramAI.shared.hasConsent {
                presentImpl?(textAlertController(context: context, title: LuckgramStrings.aiRevokeTitle, text: LuckgramStrings.aiRevokeText, actions: [
                    TextAlertAction(type: .genericAction, title: LuckgramStrings.cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: LuckgramStrings.aiRevoke, action: {
                        LuckgramAI.shared.revokeConsent()
                    })
                ]))
            } else {
                let _ = LuckgramAI.shared.requestConsent(context: context, present: { c in presentImpl?(c) }).start()
            }
        },
        footerTap: {
            let now = CFAbsoluteTimeGetCurrent()
            footerTaps = now - lastFooterTap < 0.8 ? footerTaps + 1 : 1
            lastFooterTap = now
            if footerTaps >= 7 {
                footerTaps = 0
                LuckgramSettings.shared.toggleDebugToolsUnlocked()
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                presentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: LuckgramSettings.shared.isDebugToolsVisible ? "Debug tools: on" : "Debug tools: off", timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
            }
        },
        setMock: { value in
            LuckgramAI.shared.setUseMock(value)
        },
        selfTest: {
            luckgramAISelfTest(context: context, present: { c in presentImpl?(c) })
        },
        consentCheck: {
            luckgramAIConsentCheck(context: context, present: { c in presentImpl?(c) })
        },
        resetToken: {
            LuckgramAI.shared.resetLocalState()
        }
    )

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, LuckgramSettings.shared.updated)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramStrings.featuresTitle), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luckgramSettingsEntries(), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}

// MARK: - Debug self-tests

private func luckgramAILog(context: AccountContext, title: String, lines: [String], present: (ViewController) -> Void) {
    present(textAlertController(context: context, title: title, text: lines.joined(separator: "\n"), actions: [
        TextAlertAction(type: .defaultAction, title: LuckgramStrings.ok, action: {})
    ]))
}

private func luckgramAISelfTest(context: AccountContext, present: @escaping (ViewController) -> Void) {
    let ai = LuckgramAI.shared
    let title = "LuckgramAI self-test (\(ai.isUsingMock ? "mock" : LuckgramAI.apiBaseURL))"
    ai.resetLocalState()
    var lines: [String] = []
    var deltas = 0

    let chat = ai.chat(context: context, present: present, task: .chat, messages: [.user("Say hello to Luckgram in one short sentence.")], stream: true)
    |> mapToSignal { event -> Signal<String, LuckgramAIError> in
        switch event {
        case .delta:
            deltas += 1
            return .complete()
        case let .completed(text):
            return .single(text)
        }
    }
    |> take(1)
    let transcribe = ai.transcribe(context: context, present: present, audio: LuckgramAI.testToneWav(), mimeType: "audio/wav")
    let me = ai.me(context: context, present: present)

    let _ = (chat
    |> mapToSignal { text -> Signal<LuckgramAI.Transcription, LuckgramAIError> in
        lines.append("1. register + stream chat ✓ token=\(ai.hasDeviceToken ? "yes" : "no"), \(deltas) deltas: \(text)")
        return transcribe
    }
    |> mapToSignal { transcription -> Signal<[String: Any], LuckgramAIError> in
        lines.append("2. transcribe ✓ text=\"\(transcription.text)\" language=\(transcription.language ?? "-")")
        return me
    }
    |> deliverOnMainQueue).start(next: { quota in
        let data = (try? JSONSerialization.data(withJSONObject: quota)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        lines.append("3. GET /v1/me ✓ \(data)")
        lines.append(LuckgramStrings.pick("完成", "Done"))
        luckgramAILog(context: context, title: title, lines: lines, present: present)
    }, error: { error in
        lines.append("✗ \(error.code) — \(error.localizedMessage)")
        luckgramAILog(context: context, title: title, lines: lines, present: present)
    })
}

/// Revokes consent, calls chat while declining (no presenter), checks the mock saw no request, restores consent.
private func luckgramAIConsentCheck(context: AccountContext, present: @escaping (ViewController) -> Void) {
    let ai = LuckgramAI.shared
    let hadConsent = ai.hasConsent
    let wasMock = ai.isUsingMock
    ai.setUseMock(true)
    ai.revokeConsent()
    let before = ai.mock.requestCount
    let restore: ([String]) -> Void = { lines in
        ai.setUseMock(wasMock)
        if hadConsent {
            ai.setConsent(true)
        }
        luckgramAILog(context: context, title: "LuckgramAI consent check", lines: lines + [LuckgramStrings.pick("已恢复原来的同意状态", "Original consent restored")], present: present)
    }
    let _ = (ai.chat(context: context, present: nil, task: .chat, messages: [.user("x")], stream: false)
    |> deliverOnMainQueue).start(next: { _ in
        restore(["✗ request was sent"])
    }, error: { error in
        let sent = ai.mock.requestCount - before
        restore(["\(error.code == LuckgramAIError.consentDenied && sent == 0 ? "✓" : "✗") \(error.code), requests sent: \(sent)"])
    })
}
