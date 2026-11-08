import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import MtProtoKit
import ItemListUI
import PresentationDataUtils
import AccountContext
import ShareController
import UrlEscaping
import LuckgramUI
import OverlayStatusController
import QrCodeUI
import DeviceAccess

private final class ProxySettingsControllerArguments {
    let toggleEnabled: (Bool) -> Void
    let addNewServer: () -> Void
    let activateServer: (ProxyServerSettings) -> Void
    let editServer: (ProxyServerSettings) -> Void
    let removeServer: (ProxyServerSettings) -> Void
    let setServerWithRevealedOptions: (ProxyServerSettings?, ProxyServerSettings?) -> Void
    let toggleUseForCalls: (Bool) -> Void
    let shareProxyList: () -> Void
    let refreshExits: () -> Void
    let scanQr: () -> Void
    let inputLink: () -> Void
    let openSub: (String) -> Void
    
    init(toggleEnabled: @escaping (Bool) -> Void, addNewServer: @escaping () -> Void, activateServer: @escaping (ProxyServerSettings) -> Void, editServer: @escaping (ProxyServerSettings) -> Void, removeServer: @escaping (ProxyServerSettings) -> Void, setServerWithRevealedOptions: @escaping (ProxyServerSettings?, ProxyServerSettings?) -> Void, toggleUseForCalls: @escaping (Bool) -> Void, shareProxyList: @escaping () -> Void, refreshExits: @escaping () -> Void, scanQr: @escaping () -> Void, inputLink: @escaping () -> Void, openSub: @escaping (String) -> Void) {
        self.toggleEnabled = toggleEnabled
        self.addNewServer = addNewServer
        self.activateServer = activateServer
        self.editServer = editServer
        self.removeServer = removeServer
        self.setServerWithRevealedOptions = setServerWithRevealedOptions
        self.toggleUseForCalls = toggleUseForCalls
        self.shareProxyList = shareProxyList
        self.refreshExits = refreshExits
        self.scanQr = scanQr
        self.inputLink = inputLink
        self.openSub = openSub
    }
}

private enum ProxySettingsControllerSection: Int32 {
    case enabled
    case servers
    case share
    case calls
    case subs // Luckgram 118
}

private enum ProxyServerAvailabilityStatus: Equatable {
    case checking
    case notAvailable
    case available(Int32)
}

private struct DisplayProxyServerStatus: Equatable {
    /// Luckgram 117: exit line ("出口：🇸🇬 新加坡 · 1.2.3.4"), nil when not checked (MTProto / iOS < 17).
    var exit: String? = nil
    /// Luckgram 119: "VLESS · name" for an Xray node.
    var title: String? = nil
    let activity: Bool
    let text: String
    let textActive: Bool
}

private enum ProxySettingsControllerEntryId: Equatable, Hashable {
    case index(Int)
    case server(String, Int32, ProxyServerConnection)
}

public enum ProxySettingsEntryTag: ItemListItemTag, Equatable {
    case edit
    case useProxy
    case shareList
    case useForCalls
    
    public func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? ProxySettingsEntryTag, self == other {
            return true
        } else {
            return false
        }
    }
}

private enum ProxySettingsControllerEntry: ItemListNodeEntry {
    case enabled(PresentationTheme, String, Bool, Bool)
    case serversHeader(PresentationTheme, String)
    case directExit(PresentationTheme, String, String) // Luckgram 117
    case addServer(PresentationTheme, String, Bool)
    case server(Int, PresentationTheme, PresentationStrings, ProxyServerSettings, Bool, DisplayProxyServerStatus, ProxySettingsServerItemEditing, Bool)
    case scanQr(PresentationTheme, String) // Luckgram 118
    case inputLink(PresentationTheme, String) // Luckgram 118
    case subsHeader(PresentationTheme, String) // Luckgram 118
    case sub(Int, PresentationTheme, String, String, String) // Luckgram 118: index, title, line, url
    case shareProxyList(PresentationTheme, String)
    case useForCalls(PresentationTheme, String, Bool)
    case useForCallsInfo(PresentationTheme, String)
    
    var section: ItemListSectionId {
        switch self {
            case .enabled:
                return ProxySettingsControllerSection.enabled.rawValue
            case .serversHeader, .directExit, .addServer, .server, .scanQr, .inputLink:
                return ProxySettingsControllerSection.servers.rawValue
            case .shareProxyList:
                return ProxySettingsControllerSection.share.rawValue
            case .useForCalls, .useForCallsInfo:
                return ProxySettingsControllerSection.calls.rawValue
            case .subsHeader, .sub:
                return ProxySettingsControllerSection.subs.rawValue
        }
    }
    
    var stableId: ProxySettingsControllerEntryId {
        switch self {
            case .enabled:
                return .index(0)
            case .serversHeader:
                return .index(1)
            case .addServer:
                return .index(2)
            case let .server(_, _, _, settings, _, _, _, _):
                return .server(settings.host, settings.port, settings.connection)
            case .shareProxyList:
                return .index(3)
            case .useForCalls:
                return .index(4)
            case .useForCallsInfo:
                return .index(5)
            case .directExit:
                return .index(6)
            case .scanQr:
                return .index(7)
            case .inputLink:
                return .index(8)
            case .subsHeader:
                return .index(9)
            case let .sub(index, _, _, _, _):
                return .index(1000 + index)
        }
    }
    
    static func ==(lhs: ProxySettingsControllerEntry, rhs: ProxySettingsControllerEntry) -> Bool {
        switch lhs {
            case let .enabled(lhsTheme, lhsText, lhsValue, lhsCreatesNew):
                if case let .enabled(rhsTheme, rhsText, rhsValue, rhsCreatesNew) = rhs, lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue, lhsCreatesNew == rhsCreatesNew {
                    return true
                } else {
                    return false
                }
            case let .serversHeader(lhsTheme, lhsText):
                if case let .serversHeader(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .scanQr(lhsTheme, lhsText):
                if case let .scanQr(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .inputLink(lhsTheme, lhsText):
                if case let .inputLink(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .subsHeader(lhsTheme, lhsText):
                if case let .subsHeader(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .sub(lhsIndex, lhsTheme, lhsTitle, lhsLine, lhsUrl):
                if case let .sub(rhsIndex, rhsTheme, rhsTitle, rhsLine, rhsUrl) = rhs, lhsIndex == rhsIndex, lhsTheme === rhsTheme, lhsTitle == rhsTitle, lhsLine == rhsLine, lhsUrl == rhsUrl {
                    return true
                } else {
                    return false
                }
            case let .directExit(lhsTheme, lhsTitle, lhsText):
                if case let .directExit(rhsTheme, rhsTitle, rhsText) = rhs, lhsTheme === rhsTheme, lhsTitle == rhsTitle, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .addServer(lhsTheme, lhsText, lhsEditing):
                if case let .addServer(rhsTheme, rhsText, rhsEditing) = rhs, lhsTheme === rhsTheme, lhsText == rhsText, lhsEditing == rhsEditing {
                    return true
                } else {
                    return false
                }
            case let .server(lhsIndex, lhsTheme, lhsStrings, lhsSettings, lhsActive, lhsStatus, lhsEditing, lhsEnabled):
                if case let .server(rhsIndex, rhsTheme, rhsStrings, rhsSettings, rhsActive, rhsStatus, rhsEditing, rhsEnabled) = rhs, lhsIndex == rhsIndex, lhsTheme === rhsTheme, lhsStrings === rhsStrings, lhsSettings == rhsSettings, lhsActive == rhsActive, lhsStatus == rhsStatus, lhsEditing == rhsEditing, lhsEnabled == rhsEnabled {
                    return true
                } else {
                    return false
                }
            case let .shareProxyList(lhsTheme, lhsText):
                if case let .shareProxyList(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
            case let .useForCalls(lhsTheme, lhsText, lhsValue):
                if case let .useForCalls(rhsTheme, rhsText, rhsValue) = rhs, lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue {
                    return true
                } else {
                    return false
                }
            case let .useForCallsInfo(lhsTheme, lhsText):
                if case let .useForCallsInfo(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                    return true
                } else {
                    return false
                }
        }
    }
    
    /// Order in the list (Luckgram 118 rows added; one rank per row instead of pairwise cases).
    private var rank: Int {
        switch self {
            case .enabled: return 0
            case .serversHeader: return 1
            case .directExit: return 2
            case .addServer: return 3
            case .scanQr: return 4
            case .inputLink: return 5
            case let .server(index, _, _, _, _, _, _, _): return 100 + index
            case .subsHeader: return 100_000
            case let .sub(index, _, _, _, _): return 100_001 + index
            case .shareProxyList: return 200_000
            case .useForCalls: return 200_001
            case .useForCallsInfo: return 200_002
        }
    }

    static func <(lhs: ProxySettingsControllerEntry, rhs: ProxySettingsControllerEntry) -> Bool {
        return lhs.rank < rhs.rank
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ProxySettingsControllerArguments
        switch self {
            case let .enabled(_, text, value, createsNew):
                return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, enableInteractiveChanges: !createsNew, enabled: true, sectionId: self.section, style: .blocks, updated: { value in
                    if createsNew {
                        arguments.addNewServer()
                    } else {
                        arguments.toggleEnabled(value)
                    }
                }, tag: ProxySettingsEntryTag.useProxy)
            case let .serversHeader(_, text):
                return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
            case let .directExit(_, title, text):
                return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: text, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                    arguments.refreshExits()
                })
            case let .scanQr(_, text):
                return ProxySettingsActionItem(presentationData: presentationData, systemStyle: .glass, title: text, sectionId: self.section, editing: false, action: {
                    arguments.scanQr()
                })
            case let .inputLink(_, text):
                return ProxySettingsActionItem(presentationData: presentationData, systemStyle: .glass, title: text, sectionId: self.section, editing: false, action: {
                    arguments.inputLink()
                })
            case let .subsHeader(_, text):
                return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
            case let .sub(_, _, title, line, url):
                return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: line, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                    arguments.openSub(url)
                })
            case let .addServer(_, text, _):
                return ProxySettingsActionItem(presentationData: presentationData, systemStyle: .glass, title: text, icon: .add, sectionId: self.section, editing: false, action: {
                    arguments.addNewServer()
                })
            case let .server(_, theme, strings, settings, active, status, editing, enabled):
                return ProxySettingsServerItem(theme: theme, strings: strings, systemStyle: .glass, server: settings, activity: status.activity, active: active, color: enabled ? .accent : .secondary, label: status.text, labelAccent: status.textActive, exitLabel: status.exit, titleOverride: status.title, editing: editing, sectionId: self.section, action: {
                    arguments.activateServer(settings)
                }, infoAction: {
                    arguments.editServer(settings)
                }, setServerWithRevealedOptions: { lhs, rhs in
                    arguments.setServerWithRevealedOptions(lhs, rhs)
                }, removeServer: { _ in
                    arguments.removeServer(settings)
                })
            case let .shareProxyList(_, text):
                return ProxySettingsActionItem(presentationData: presentationData, systemStyle: .glass, title: text, sectionId: self.section, editing: false, action: {
                    arguments.shareProxyList()
                }, tag: ProxySettingsEntryTag.shareList)
            case let .useForCalls(_, text, value):
                return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, enableInteractiveChanges: true, enabled: true, sectionId: self.section, style: .blocks, updated: { value in
                    arguments.toggleUseForCalls(value)
                }, tag: ProxySettingsEntryTag.useForCalls)
            case let .useForCallsInfo(_, text):
                return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func proxySettingsControllerEntries(theme: PresentationTheme, strings: PresentationStrings, state: ProxySettingsControllerState, proxySettings: ProxySettings, statuses: [ProxyServerSettings: ProxyServerStatus], connectionStatus: ConnectionStatus, exits: [String: LuckgramProxyExitChecker.State], canScan: Bool, subs: [LuckgramProxyImport.Sub]) -> [ProxySettingsControllerEntry] {
    var entries: [ProxySettingsControllerEntry] = []
    let exitTexts = LuckgramProxyExitTexts(zh: LuckgramStrings.isChinese)
    func exitText(_ key: String) -> String {
        switch exits[key] {
        case let .done(exit):
            return exitTexts.line(for: exit)
        case .failed:
            return exitTexts.failed
        case .checking, .none:
            return exitTexts.checking
        }
    }

    entries.append(.enabled(theme, strings.ChatSettings_ConnectionType_UseProxy, proxySettings.enabled, proxySettings.servers.isEmpty))
    entries.append(.serversHeader(theme, strings.SocksProxySetup_SavedProxies))
    entries.append(.directExit(theme, exitTexts.directTitle, exitText(LuckgramProxyExitChecker.directKey)))
    entries.append(.addServer(theme, strings.SocksProxySetup_AddProxy, state.editing))
    // Luckgram 118: scan a QR code, type a link or subscription URL, saved subscriptions
    let importTexts = LuckgramProxyImportTexts(zh: LuckgramStrings.isChinese)
    if canScan {
        entries.append(.scanQr(theme, importTexts.scanRow))
    }
    entries.append(.inputLink(theme, importTexts.linkRow))
    if !subs.isEmpty {
        entries.append(.subsHeader(theme, importTexts.subsHeader))
        for (i, sub) in subs.enumerated() {
            entries.append(.sub(i, theme, sub.title, LuckgramProxyImport.subLine(sub, zh: LuckgramStrings.isChinese), sub.url))
        }
    }
    var index = 0
    var existingServers = Set<ProxyServerSettings>()
    for server in proxySettings.servers {
        if !existingServers.insert(server).inserted {
            continue
        }
        let status: ProxyServerStatus = statuses[server] ?? .checking
        var displayStatus: DisplayProxyServerStatus
        if proxySettings.enabled && server == proxySettings.activeServer {
            switch connectionStatus {
                case .waitingForNetwork:
                    displayStatus = DisplayProxyServerStatus(activity: true, text: strings.State_WaitingForNetwork.lowercased(), textActive: false)
                case .connecting, .updating:
                    displayStatus = DisplayProxyServerStatus(activity: true, text: strings.SocksProxySetup_ProxyStatusConnecting, textActive: false)
                case .online:
                    var text = strings.SocksProxySetup_ProxyStatusConnected
                    if case let .available(rtt) = status {
                        let pingTime: Int = Int(rtt * 1000.0)
                        text = text + ", \(strings.SocksProxySetup_ProxyStatusPing("\(pingTime)").string)"
                    }
                    displayStatus = DisplayProxyServerStatus(activity: false, text: text, textActive: true)
            }
        } else if case .web = server.connection {
            // ProxyServersStatuses never pings WEB servers, so consulting `status` here
            // would leave the row reading "checking..." forever. Composed the same way as the
            // active row below, which appends its ping to the type the same way.
            displayStatus = DisplayProxyServerStatus(activity: false, text: "\(strings.SocksProxySetup_ProxyWeb), \(strings.SocksProxySetup_ProxyStatusNotTested)", textActive: false)
        } else {
            var text: String
            switch server.connection {
                case .socks5:
                    text = strings.ChatSettings_ConnectionType_UseSocks5
                case .mtp:
                    text = strings.SocksProxySetup_ProxyTelegram
                case .web:
                    // Unreachable - the branch above catches every WEB server - but naming it
                    // MTProto here would be wrong if that ordering ever changed.
                    text = strings.SocksProxySetup_ProxyWeb
            }
            switch status {
                case .notAvailable:
                    text = text + ", " + strings.SocksProxySetup_ProxyStatusUnavailable
                    displayStatus = DisplayProxyServerStatus(activity: false, text: text, textActive: false)
                case .checking:
                    text = text + ", " + strings.SocksProxySetup_ProxyStatusChecking
                    displayStatus = DisplayProxyServerStatus(activity: false, text: text, textActive: false)
                case let .available(rtt):
                    let pingTime: Int = Int(rtt * 1000.0)
                    text = text + ", \(strings.SocksProxySetup_ProxyStatusPing("\(pingTime)").string)"
                    displayStatus = DisplayProxyServerStatus(activity: false, text: text, textActive: false)
            }
        }
        if let socks = luckgramExitSocks(server), let key = LuckgramProxyExitChecker.key(socks) {
            displayStatus.exit = exitText(key)
        }
        // Luckgram 119: an Xray node shows its protocol and real server, and the core's state
        if let xray = luckgramXrayNode(server) {
            if let problem = LuckgramXrayManager.shared.problem(zh: LuckgramStrings.isChinese) {
                displayStatus = DisplayProxyServerStatus(exit: displayStatus.exit, activity: false, text: problem, textActive: false)
            }
            displayStatus.title = LuckgramXrayLogic.label(xray.proto) + " · " + xray.title
        }
        entries.append(.server(index, theme, strings, server, server == proxySettings.activeServer, displayStatus, ProxySettingsServerItemEditing(editable: true, editing: state.editing, revealed: state.revealedServer == server), proxySettings.enabled))
        index += 1
    }
    if !existingServers.isEmpty {
        entries.append(.shareProxyList(theme, strings.SocksProxySetup_ShareProxyList))
    }
    
    if let activeServer = proxySettings.activeServer, case .socks5 = activeServer.connection {
        entries.append(.useForCalls(theme, strings.SocksProxySetup_UseForCalls, proxySettings.useForCalls))
        entries.append(.useForCallsInfo(theme, strings.SocksProxySetup_UseForCallsHelp))
    }
    
    // ItemList asserts sorted entries; Luckgram 118 rows are appended out of rank order
    return entries.sorted(by: <)
}

/// Luckgram 119: the Xray node behind a server (a 127.0.0.1 SOCKS5 with our username), or nil.
private func luckgramXrayNode(_ server: ProxyServerSettings) -> LuckgramXrayManager.Rec? {
    guard case let .socks5(username, _) = server.connection else { return nil }
    return LuckgramXrayManager.shared.node(host: server.host, port: Int(server.port), username: username)
}

/// Luckgram 119: local ports of the Xray nodes still in Telegram's list.
private func luckgramXrayLivePorts(_ settings: ProxySettings) -> Set<Int> {
    var out = Set<Int>()
    for server in settings.servers {
        if case let .socks5(username, _) = server.connection, server.host == LuckgramXrayManager.localHost, username == LuckgramXrayManager.user {
            out.insert(Int(server.port))
        }
    }
    return out
}

/// Luckgram 118: a proxy from a link or subscription as Telegram's server settings.
/// Luckgram 119: an Xray node becomes the loopback SOCKS5 of the built-in core (nil when the core
/// is off, missing or cannot build the node).
private func luckgramServer(_ e: LuckgramProxyImportLogic.Entry) -> ProxyServerSettings? {
    if e.type == LuckgramProxyImportLogic.typeXray {
        let manager = LuckgramXrayManager.shared
        guard manager.isEnabled, let node = LuckgramXrayLogic.parse(e.link), let port = manager.register(node) else { return nil }
        return ProxyServerSettings(host: LuckgramXrayManager.localHost, port: Int32(port), connection: .socks5(username: LuckgramXrayManager.user, password: manager.password))
    }
    if e.type == LuckgramProxyImportLogic.typeMtproto {
        guard let secret = MTProxySecret.parse(e.secret)?.serialize() else {
            return nil
        }
        return ProxyServerSettings(host: e.host, port: Int32(e.port), connection: .mtp(secret: secret))
    }
    return ProxyServerSettings(host: e.host, port: Int32(e.port), connection: .socks5(username: e.user.isEmpty ? nil : e.user, password: e.password.isEmpty ? nil : e.password))
}

/// Luckgram 118: identity of a server (MTProto secret as hex), for subscription refresh.
private func luckgramEntry(_ server: ProxyServerSettings) -> LuckgramProxyImportLogic.Entry? {
    if let xray = luckgramXrayNode(server), let node = LuckgramXrayLogic.parse(xray.link) {
        return LuckgramProxyImportLogic.Entry(xray: node)
    }
    switch server.connection {
    case let .socks5(username, password):
        return LuckgramProxyImportLogic.Entry(type: LuckgramProxyImportLogic.typeSocks5, host: server.host, port: Int(server.port), user: username, password: password, secret: nil)
    case let .mtp(secret):
        return LuckgramProxyImportLogic.Entry(type: LuckgramProxyImportLogic.typeMtproto, host: server.host, port: Int(server.port), user: nil, password: nil, secret: secret.map { String(format: "%02x", $0) }.joined())
    case .web:
        return nil
    }
}

/// Luckgram 117: the SOCKS5 parameters of a server whose exit can be checked.
private func luckgramExitSocks(_ server: ProxyServerSettings) -> LuckgramProxyExitChecker.Socks? {
    if case let .socks5(username, password) = server.connection {
        return LuckgramProxyExitChecker.Socks(host: server.host, port: Int(server.port), username: username, password: password)
    }
    return nil
}

private struct ProxySettingsControllerState: Equatable {
    var editing: Bool = false
    var revealedServer: ProxyServerSettings? = nil
}

public enum ProxySettingsControllerMode {
    case `default`
    case modal
}

public func proxySettingsController(context: AccountContext, mode: ProxySettingsControllerMode = .default, focusOnItemTag: ProxySettingsEntryTag? = nil) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    return proxySettingsController(accountManager: context.sharedContext.accountManager, sharedContext: context.sharedContext, context: context, network: context.account.network, mode: mode, presentationData: presentationData, updatedPresentationData: context.sharedContext.presentationData, focusOnItemTag: focusOnItemTag)
}

public func proxySettingsController(accountManager: AccountManager<TelegramAccountManagerTypes>, sharedContext: SharedAccountContext, context: AccountContext? = nil, network: Network, mode: ProxySettingsControllerMode, presentationData: PresentationData, updatedPresentationData: Signal<PresentationData, NoError>, focusOnItemTag: ProxySettingsEntryTag? = nil) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?
    let stateValue = Atomic(value: ProxySettingsControllerState())
    let statePromise = ValuePromise<ProxySettingsControllerState>(stateValue.with { $0 })
    let updateState: ((ProxySettingsControllerState) -> ProxySettingsControllerState) -> Void = { f in
        var changed = false
        let value = stateValue.modify { current in
            let updated = f(current)
            if updated != current {
                changed = true
            }
            return updated
        }
        if changed {
            statePromise.set(value)
        }
    }
    
    if focusOnItemTag == ProxySettingsEntryTag.edit {
        updateState { state in
            var state = state
            state.editing = true
            return state
        }
    }
    
    var shareProxyListImpl: (() -> Void)?
    var refreshExitsImpl: (() -> Void)?
    var scanQrImpl: (() -> Void)?
    var inputLinkImpl: (() -> Void)?
    var openSubImpl: ((String) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var luckgramAlertImpl: ((String) -> Void)?
    var luckgramXrayMenuImpl: ((ProxyServerSettings, LuckgramXrayManager.Rec) -> Void)?
    // Luckgram 119: redraw when the Xray core starts, stops or fails
    let xrayTick = ValuePromise<Int>(0, ignoreRepeated: false)
    var xrayTickValue = 0
    var xrayLastPorts: Set<Int>?
    LuckgramXrayManager.shared.onStateChanged = {
        xrayTickValue += 1
        xrayTick.set(xrayTickValue)
    }
    let subsPromise = ValuePromise<[LuckgramProxyImport.Sub]>(LuckgramProxyImport.subs(), ignoreRepeated: true)
    
    let arguments = ProxySettingsControllerArguments(toggleEnabled: { value in
        let _ = updateProxySettingsInteractively(accountManager: accountManager, { current in
            var current = current
            current.enabled = value
            return current
        }).start()
    }, addNewServer: {
        pushControllerImpl?(proxyServerSettingsController(sharedContext: sharedContext, presentationData: presentationData, updatedPresentationData: updatedPresentationData, accountManager: accountManager, network: network, currentSettings: nil))
    }, activateServer: { server in
        if luckgramXrayNode(server) != nil, !LuckgramXrayManager.shared.isEnabled {
            // Luckgram 119: not selectable while the core is off or missing
            luckgramAlertImpl?(LuckgramXrayManager.shared.problem(zh: LuckgramStrings.isChinese) ?? "")
            return
        }
        let _ = updateProxySettingsInteractively(accountManager: accountManager, { current in
            var current = current
            if current.activeServer != server {
                if let _ = current.servers.firstIndex(of: server) {
                    current.activeServer = server
                    current.enabled = true
                }
            }
            return current
        }).start()
    }, editServer: { server in
        if let xray = luckgramXrayNode(server) {
            // Luckgram 119: an Xray node is not edited as the loopback SOCKS5 it runs as
            luckgramXrayMenuImpl?(server, xray)
            return
        }
        pushControllerImpl?(proxyServerSettingsController(sharedContext: sharedContext, presentationData: presentationData, updatedPresentationData: updatedPresentationData, accountManager: accountManager, network: network, currentSettings: server))
    }, removeServer: { server in
        let _ = updateProxySettingsInteractively(accountManager: accountManager, { current in
            var current = current
            if let index = current.servers.firstIndex(of: server) {
                current.servers.remove(at: index)
                if current.activeServer == server {
                    current.activeServer = nil
                    current.enabled = false
                }
            }
            return current
        }).start()
    }, setServerWithRevealedOptions: { server, fromServer in
        updateState { state in
            var state = state
            if (server == nil && fromServer == state.revealedServer) || (server != nil && fromServer == nil) {
                state.revealedServer = server
            }
            return state
        }
    }, toggleUseForCalls: { value in
        let _ = updateProxySettingsInteractively(accountManager: accountManager, { current in
            var current = current
            current.useForCalls = value
            return current
        }).start()
    }, shareProxyList: {
       shareProxyListImpl?()
    }, refreshExits: {
        refreshExitsImpl?()
    }, scanQr: {
        scanQrImpl?()
    }, inputLink: {
        inputLinkImpl?()
    }, openSub: { url in
        openSubImpl?(url)
    })
    
    let proxySettings = Promise<ProxySettings>()
    proxySettings.set(accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
    |> map { sharedData -> ProxySettings in
        if let value = sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) {
            return value
        } else {
            return ProxySettings.defaultSettings
        }
    })
    
    let statusesContext = ProxyServersStatuses(network: network, servers: proxySettings.get()
    |> map { proxySettings -> [ProxyServerSettings] in
        return proxySettings.servers
    })
    
    // Luckgram 117: exits of the direct connection and of each SOCKS5 proxy (cached 10 minutes).
    let exitChecker = LuckgramProxyExitChecker.shared
    refreshExitsImpl = {
        let _ = (proxySettings.get() |> take(1)).start(next: { settings in
            exitChecker.ensure(proxies: settings.servers.compactMap(luckgramExitSocks), force: true)
        })
    }
    let signal = combineLatest(updatedPresentationData, statePromise.get(), proxySettings.get(), statusesContext.statuses(), network.connectionStatus, exitChecker.statesSignal(), subsPromise.get(), xrayTick.get())
    |> map { presentationData, state, proxySettings, statuses, connectionStatus, exits, subs, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        // Luckgram 119: when the Xray nodes in the list change (added, imported, deleted here or by
        // swiping), drop the nodes that left and restart the core with the rest
        let xrayPorts = luckgramXrayLivePorts(proxySettings)
        if xrayPorts != xrayLastPorts {
            let force = xrayLastPorts != nil
            xrayLastPorts = xrayPorts
            LuckgramXrayManager.shared.reconcile(livePorts: xrayPorts, forceApply: force)
        }
        exitChecker.ensure(proxies: proxySettings.servers.compactMap(luckgramExitSocks), force: false)
        var presentationData = presentationData
        let updatedTheme = presentationData.theme.withModalBlocksBackground()
        presentationData = presentationData.withUpdated(theme: updatedTheme)
        
        var leftNavigationButton: ItemListNavigationButton?
        if case .modal = mode {
            leftNavigationButton = ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
                dismissImpl?()
            })
        }
        
        let rightNavigationButton: ItemListNavigationButton?
        if proxySettings.servers.isEmpty {
            rightNavigationButton = nil
        } else if state.editing {
            rightNavigationButton = ItemListNavigationButton(content: .icon(.done), style: .bold, enabled: true, staysInRow: true, action: {
                updateState { state in
                    var state = state
                    state.editing = false
                    return state
                }
            })
        } else {
            rightNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Edit), style: .regular, enabled: true, action: {
                updateState { state in
                    var state = state
                    state.editing = true
                    return state
                }
            })
        }
        
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.SocksProxySetup_Title), leftNavigationButton: leftNavigationButton, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: proxySettingsControllerEntries(theme: presentationData.theme, strings: presentationData.strings, state: state, proxySettings: proxySettings, statuses: statuses, connectionStatus: connectionStatus, exits: exits, canScan: context != nil, subs: subs), style: .blocks, ensureVisibleItemTag: focusOnItemTag)
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(presentationData: ItemListPresentationData(presentationData), updatedPresentationData: updatedPresentationData |> map(ItemListPresentationData.init(_:)), state: signal, tabBarItem: nil)
    controller.navigationPresentation = .modal
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }

    // Luckgram 118: add proxies from a QR code or a link, import / refresh / delete subscriptions
    let importTexts = LuckgramProxyImportTexts(zh: LuckgramStrings.isChinese)
    let alert: (String?, String) -> Void = { title, text in
        presentImpl?(textAlertController(sharedContext: sharedContext, title: title, text: text, actions: [TextAlertAction(type: .defaultAction, title: importTexts.ok, action: {})]))
    }
    luckgramAlertImpl = { text in
        alert(nil, text)
    }
    luckgramXrayMenuImpl = { server, xray in
        let texts = LuckgramXrayTexts(zh: LuckgramStrings.isChinese)
        presentImpl?(textAlertController(sharedContext: sharedContext, title: xray.title, text: xray.detail, actions: [
            TextAlertAction(type: .genericAction, title: texts.copyLink, action: {
                UIPasteboard.general.string = xray.link
                presentImpl?(OverlayStatusController(style: presentationData.theme.overallDarkAppearance ? .dark : .light, type: .genericSuccess(texts.linkCopied, false)))
            }),
            TextAlertAction(type: .destructiveAction, title: texts.delete, action: {
                arguments.removeServer(server)
            }),
            TextAlertAction(type: .defaultAction, title: importTexts.cancel, action: {})
        ], actionLayout: .vertical))
    }
    let applySubscription: (String, LuckgramProxyImportLogic.Result, Bool) -> Void = { url, result, isRefresh in
        let previous = Set(LuckgramProxyImport.subs().first(where: { $0.url == url })?.keys ?? [])
        // keys through ProxyServerSettings so MTProto secrets compare in one form
        let now: [(LuckgramProxyImportLogic.Entry, ProxyServerSettings)] = result.proxies.compactMap { e in
            guard let server = luckgramServer(e), let k = luckgramEntry(server) else { return nil }
            return (k, server)
        }
        // Xray nodes the core cannot use (off, missing, unbuildable) count as skipped
        let skipped = result.skipped + (result.proxies.count - now.count)
        let coreOff = !LuckgramXrayManager.shared.isEnabled && result.proxies.contains(where: { $0.type == LuckgramProxyImportLogic.typeXray })
        var added = 0
        var removed = 0
        var owned: [String] = []
        let _ = (updateProxySettingsInteractively(accountManager: accountManager, { current in
            var current = current
            let existing = Set(current.servers.compactMap { luckgramEntry($0)?.key })
            let diff = LuckgramProxyImportLogic.diff(previouslyImported: previous, now: now.map { $0.0 }, existing: existing)
            // the subscription owns what it added now or before; proxies added by hand stay the user's
            owned = LuckgramProxyImportLogic.owned(previouslyOwned: previous, now: now.map { $0.0 }, diff: diff)
            let removeKeys = Set(diff.remove)
            let before = current.servers.count
            current.servers.removeAll(where: { server in luckgramEntry(server).map { removeKeys.contains($0.key) } ?? false })
            removed = before - current.servers.count
            if let active = current.activeServer, !current.servers.contains(active) {
                current.activeServer = nil
                current.enabled = false
            }
            let addKeys = Set(diff.add.map { $0.key })
            for (k, server) in now where addKeys.contains(k.key) && !current.servers.contains(server) {
                current.servers.append(server)
                added += 1
            }
            return current
        }) |> deliverOnMainQueue).start(completed: {
            LuckgramProxyImport.record(url: url, keys: owned)
            subsPromise.set(LuckgramProxyImport.subs())
            alert(isRefresh ? importTexts.refreshTitle : importTexts.importTitle, importTexts.result(total: now.count, added: added, removed: removed, skipped: skipped, coreProblem: coreOff ? LuckgramXrayManager.shared.problem(zh: LuckgramStrings.isChinese) : nil))
        })
    }
    let importSubscription: (String, Bool) -> Void = { url, isRefresh in
        let progress = OverlayStatusController(style: presentationData.theme.overallDarkAppearance ? .dark : .light, type: .loading(cancelled: nil))
        presentImpl?(progress)
        let _ = (proxySettings.get() |> take(1) |> deliverOnMainQueue).start(next: { settings in
            var via: LuckgramProxyExitChecker.Socks?
            if settings.enabled, let active = settings.activeServer, case let .socks5(username, password) = active.connection {
                via = LuckgramProxyExitChecker.Socks(host: active.host, port: Int(active.port), username: username, password: password)
            }
            LuckgramProxyImport.download(url: url, via: via) { body in
                progress.dismiss()
                guard let body else {
                    alert(importTexts.importTitle, importTexts.downloadFailed)
                    return
                }
                applySubscription(url, LuckgramProxyImportLogic.parseSubscription(body), isRefresh)
            }
        })
    }
    let handleText: (String) -> Void = { raw in
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch LuckgramProxyImportLogic.kind(text) {
        case .proxy:
            guard let e = LuckgramProxyImportLogic.parseLink(text) else {
                alert(importTexts.unknownTitle, importTexts.unknown)
                return
            }
            if e.type == LuckgramProxyImportLogic.typeXray, !LuckgramXrayManager.shared.isEnabled {
                alert(importTexts.inputTitle, LuckgramXrayManager.shared.problem(zh: LuckgramStrings.isChinese) ?? "")
                return
            }
            guard let server = luckgramServer(e) else {
                alert(importTexts.inputTitle, e.type == LuckgramProxyImportLogic.typeXray ? LuckgramXrayTexts(zh: LuckgramStrings.isChinese).unavailable : importTexts.unknown)
                return
            }
            var existed = false
            let _ = (updateProxySettingsInteractively(accountManager: accountManager, { current in
                var current = current
                if current.servers.contains(server) {
                    existed = true
                } else {
                    current.servers.insert(server, at: 0)
                }
                return current
            }) |> deliverOnMainQueue).start(completed: {
                presentImpl?(OverlayStatusController(style: presentationData.theme.overallDarkAppearance ? .dark : .light, type: .genericSuccess(existed ? importTexts.alreadyAdded : importTexts.added, false)))
            })
        case .subscription:
            importSubscription(text, false)
        case .unknown:
            alert(importTexts.unknownTitle, importTexts.unknown)
        }
    }
    inputLinkImpl = {
        let c = UIAlertController(title: importTexts.inputTitle, message: importTexts.inputMessage, preferredStyle: .alert)
        c.addTextField { field in
            field.placeholder = importTexts.inputHint
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        c.addAction(UIAlertAction(title: importTexts.cancel, style: .cancel))
        c.addAction(UIAlertAction(title: importTexts.add, style: .default, handler: { [weak c] _ in
            handleText(c?.textFields?.first?.text ?? "")
        }))
        sharedContext.applicationBindings.presentNativeController(c)
    }
    scanQrImpl = {
        guard let context else {
            return
        }
        DeviceAccess.authorizeAccess(to: .camera(.qrCode), presentationData: presentationData, present: { c, a in
            c.presentationArguments = a
            presentImpl?(c)
        }, openSettings: {
            sharedContext.applicationBindings.openSettings()
        }, { granted in
            guard granted else {
                return
            }
            let scanner = QrCodeScanScreen(context: context, subject: .custom(info: importTexts.scanHint))
            scanner.completion = { [weak scanner] code in
                scanner?.dismissAnimated()
                guard let code else {
                    return
                }
                Queue.mainQueue().after(0.3) {
                    handleText(code)
                }
            }
            presentImpl?(scanner)
        })
    }
    openSubImpl = { url in
        guard let sub = LuckgramProxyImport.subs().first(where: { $0.url == url }) else {
            return
        }
        presentImpl?(textAlertController(sharedContext: sharedContext, title: sub.title, text: LuckgramProxyImport.subLine(sub, zh: LuckgramStrings.isChinese), actions: [
            TextAlertAction(type: .defaultAction, title: importTexts.refresh, action: {
                importSubscription(url, true)
            }),
            TextAlertAction(type: .destructiveAction, title: importTexts.delete, action: {
                presentImpl?(textAlertController(sharedContext: sharedContext, title: importTexts.deleteTitle, text: importTexts.deleteMessage(sub.keys.count), actions: [
                    TextAlertAction(type: .genericAction, title: importTexts.cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: importTexts.delete, action: {
                        let keys = Set(sub.keys)
                        let _ = (updateProxySettingsInteractively(accountManager: accountManager, { current in
                            var current = current
                            current.servers.removeAll(where: { server in luckgramEntry(server).map { keys.contains($0.key) } ?? false })
                            if let active = current.activeServer, !current.servers.contains(active) {
                                current.activeServer = nil
                                current.enabled = false
                            }
                            return current
                        }) |> deliverOnMainQueue).start(completed: {
                            LuckgramProxyImport.remove(url: url)
                            subsPromise.set(LuckgramProxyImport.subs())
                        })
                    })
                ]))
            }),
            TextAlertAction(type: .genericAction, title: importTexts.cancel, action: {})
        ], actionLayout: .vertical))
    }
    controller.setReorderEntry({ (fromIndex: Int, toIndex: Int, entries: [ProxySettingsControllerEntry]) -> Signal<Bool, NoError> in
        let fromEntry = entries[fromIndex]
        guard case let .server(_, _, _, fromServer, _, _, _, _) = fromEntry else {
            return .single(false)
        }
        var referenceServer: ProxyServerSettings?
        var beforeAll = false
        var afterAll = false
        if toIndex < entries.count {
            switch entries[toIndex] {
                case let .server(_, _, _, toServer, _, _, _, _):
                    referenceServer = toServer
                default:
                    if entries[toIndex] < fromEntry {
                        beforeAll = true
                    } else {
                        afterAll = true
                    }
            }
        } else {
            afterAll = true
        }

        return updateProxySettingsInteractively(accountManager: accountManager, { current in
            var current = current
            if let index = current.servers.firstIndex(of: fromServer) {
                current.servers.remove(at: index)
            }
            if let referenceServer = referenceServer {
                var inserted = false
                for i in 0 ..< current.servers.count {
                    if current.servers[i] == referenceServer {
                        if fromIndex < toIndex {
                            current.servers.insert(fromServer, at: i + 1)
                        } else {
                            current.servers.insert(fromServer, at: i)
                        }
                        inserted = true
                        break
                    }
                }
                if !inserted {
                    current.servers.append(fromServer)
                }
            } else if beforeAll {
                current.servers.insert(fromServer, at: 0)
            } else if afterAll {
                current.servers.append(fromServer)
            }
            return current
        })
    })
    
    shareProxyListImpl = { [weak controller] in
        guard let context = context, let strongController = controller else {
            return
        }
        let _ = (proxySettings.get()
            |> take(1)
            |> deliverOnMainQueue).start(next: { settings in
                var result = ""
                for server in settings.servers {
                    var string: String
                    switch server.connection {
                    case let .mtp(secret):
                        let secret = MTProxySecret.parseData(secret)?.serializeToString() ?? ""
                        string = "https://t.me/proxy?server=\(server.host)&port=\(server.port)"
                        string += "&secret=\((secret as NSString).addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryValueAllowed) ?? "")"
                    case let .socks5(username, password):
                        string = "https://t.me/socks?server=\(server.host)&port=\(server.port)"
                        if let username = username, let password = password {
                            string += "&user=\((username as NSString).addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryValueAllowed) ?? "")&pass=\((password as NSString).addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryValueAllowed) ?? "")"
                        }
                    case .web:
                        // nil when a stored server no longer canonicalizes. Skip it rather
                        // than contributing an empty entry and a stray blank line.
                        guard let link = webProxySettingsLink(server) else {
                            continue
                        }
                        string = link
                    }
                    
                    if !result.isEmpty {
                        result += "\n\n"
                    }
                    result += string
                }
                
                presentExternalShare(context: context, text: result, parentController: strongController)
            })
    }
    
    if let focusOnItemTag {
        var didFocusOnItem = false
        controller.afterTransactionCompleted = { [weak controller] in
            if !didFocusOnItem, let controller {
                controller.forEachItemNode { itemNode in
                    if let itemNode = itemNode as? ItemListItemNode, let tag = itemNode.tag, tag.isEqual(to: focusOnItemTag) {
                        didFocusOnItem = true
                        itemNode.displayHighlight()
                    }
                }
            }
        }
    }
    
    return controller
}
