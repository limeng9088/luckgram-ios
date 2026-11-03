import Foundation

/// specs#92: chat list 「+」 menu → 扫一扫. What a scanned QR code is, so it goes to Telegram's own flow:
/// login token, proxy, a Telegram link (profile / group / channel), another web link, or plain text.
/// Also the proxy state shown next to 「代理配置」 and the texts. Foundation only; unit-tested in
/// `LuckgramScanLogicTests` (same rules as Android `ScanLogic`).
public enum LuckgramScanLogic {
    /// Feature switch (default on); off = the chat list title bar is Telegram's again.
    public static let featureKey = "chat_plus_menu"
    public static let loginPrefix = "tg://login?token="

    public enum Kind: Equatable {
        case text
        case login
        case proxy
        case telegram
        case web
    }

    public enum ProxyState: Equatable {
        case off
        case connecting
        case connected
    }

    public static func kind(_ raw: String?) -> Kind {
        guard let raw else {
            return .text
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.contains("\n") || text.contains(" ") {
            return .text
        }
        let lower = text.lowercased()
        if lower.hasPrefix(loginPrefix) {
            return .login
        }
        if isProxy(lower) {
            return .proxy
        }
        if lower.hasPrefix("tg:") {
            return .telegram
        }
        guard let host = webHost(lower) else {
            return .text
        }
        if isTelegramHost(host) {
            return firstPathSegment(lower).isEmpty ? .web : .telegram
        }
        return .web
    }

    static func isProxy(_ lower: String) -> Bool {
        for p in ["tg:proxy", "tg://proxy", "tg:socks", "tg://socks", "tg:webproxy", "tg://webproxy"] where lower.hasPrefix(p + "?") {
            return true
        }
        guard let host = webHost(lower), isTelegramHost(host) else {
            return false
        }
        let path = firstPathSegment(lower)
        return path == "proxy" || path == "socks"
    }

    /// The URL to open for a scanned text: adds https:// to a bare t.me/… link.
    public static func url(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") && !lower.hasPrefix("tg:") {
            return "https://" + text
        }
        return text
    }

    /// The token of `tg://login?token=…` (base64url), or nil.
    public static func loginToken(_ raw: String) -> Data? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix(loginPrefix) else {
            return nil
        }
        var token = String(text.dropFirst(loginPrefix.count))
        if let amp = token.firstIndex(of: "&") {
            token = String(token[..<amp])
        }
        token = token.removingPercentEncoding ?? token
        token = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while token.count % 4 != 0 {
            token.append("=")
        }
        guard !token.isEmpty, let data = Data(base64Encoded: token), !data.isEmpty else {
            return nil
        }
        return data
    }

    public static func proxyState(enabled: Bool, connected: Bool) -> ProxyState {
        if !enabled {
            return .off
        }
        return connected ? .connected : .connecting
    }

    private static func webHost(_ lower: String) -> String? {
        let rest: Substring
        if lower.hasPrefix("https://") {
            rest = lower.dropFirst(8)
        } else if lower.hasPrefix("http://") {
            rest = lower.dropFirst(7)
        } else if lower.hasPrefix("t.me/") || lower.hasPrefix("telegram.me/") || lower.hasPrefix("telegram.dog/") {
            rest = Substring(lower)
        } else {
            return nil
        }
        var host = String(rest.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host.isEmpty ? nil : host
    }

    private static func isTelegramHost(_ host: String) -> Bool {
        return host == "t.me" || host == "telegram.me" || host == "telegram.dog"
    }

    private static func firstPathSegment(_ lower: String) -> String {
        var rest = Substring(lower)
        if let r = lower.range(of: "://") {
            rest = lower[r.upperBound...]
        }
        guard let slash = rest.firstIndex(of: "/") else {
            return ""
        }
        return String(rest[rest.index(after: slash)...].prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
    }

    public struct Texts {
        let zh: Bool

        public init(zh: Bool) {
            self.zh = zh
        }

        private func t(_ zh: String, _ en: String) -> String {
            return self.zh ? zh : en
        }

        public var plus: String { return t("更多", "More") }
        public var scan: String { return t("扫一扫", "Scan") }
        public var proxy: String { return t("代理配置", "Proxy settings") }
        public func proxyState(_ state: ProxyState) -> String {
            switch state {
            case .connected:
                return t("已连接", "Connected")
            case .connecting:
                return t("连接中", "Connecting")
            case .off:
                return t("未开启", "Off")
            }
        }
        public var scanHint: String { return t("扫描 Telegram 二维码：加好友、加群、添加代理或在其他设备登录", "Scan a Telegram QR code: add a friend, join a group, add a proxy or log in on another device") }
        public var myQr: String { return t("我的二维码", "My QR code") }
        public var loginTitle: String { return t("在其他设备登录", "Log in on another device") }
        public var loginConfirm: String { return t("确定要用当前账号登录扫码的设备吗？只确认你自己的设备。", "Log in to the scanned device with this account? Only confirm devices that are yours.") }
        public var login: String { return t("登录", "Log in") }
        public var loginDone: String { return t("已在其他设备登录", "Logged in on the other device") }
        public var loginFailed: String { return t("登录失败，二维码可能已过期，请刷新后重试", "Couldn't log in. The QR code may have expired; refresh it and try again") }
        public var openLink: String { return t("打开链接？", "Open this link?") }
        public var open: String { return t("打开", "Open") }
        public var text: String { return t("扫描结果", "Scan result") }
        public var copy: String { return t("复制", "Copy") }
        public var copied: String { return t("已复制", "Copied") }
        public var cancel: String { return t("取消", "Cancel") }
    }
}
