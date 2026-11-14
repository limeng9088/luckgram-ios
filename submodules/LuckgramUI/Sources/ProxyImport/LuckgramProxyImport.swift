import Foundation
import Network

/// specs#118: saved mihomo / Clash subscriptions (on this device only) and their download.
/// The proxy list (SettingsUI) applies the result to Telegram's proxy settings.
public final class LuckgramProxyImport {
    public struct Sub: Codable, Equatable {
        public let url: String
        public var updated: Double
        public var keys: [String]

        public var title: String {
            return LuckgramProxyImportLogic.hostOf(url) ?? url
        }
    }

    private static let defaultsKey = "luckgram_proxy_subs"
    private static let timeout: TimeInterval = 20
    private static let userAgent = "clash.meta"

    public static func subs() -> [Sub] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey), let list = try? JSONDecoder().decode([Sub].self, from: data) else {
            return []
        }
        return list
    }

    public static func save(_ list: [Sub]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Records a finished import or refresh.
    public static func record(url: String, keys: [String]) {
        var list = subs()
        if let i = list.firstIndex(where: { $0.url == url }) {
            list[i].keys = keys
            list[i].updated = Date().timeIntervalSince1970
        } else {
            list.append(Sub(url: url, updated: Date().timeIntervalSince1970, keys: keys))
        }
        save(list)
    }

    public static func remove(url: String) {
        save(subs().filter { $0.url != url })
    }

    /// Downloads a subscription: directly first, then through `via` (the active SOCKS5 proxy, iOS 17+).
    /// Completion on the main queue with the body, or nil.
    public static func download(url: String, via: LuckgramProxyExitChecker.Socks?, completion: @escaping (String?) -> Void) {
        fetch(url: url, via: nil) { body in
            if let body {
                DispatchQueue.main.async { completion(body) }
                return
            }
            guard let via, url.lowercased().hasPrefix("https://") else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            fetch(url: url, via: via) { body in
                DispatchQueue.main.async { completion(body) }
            }
        }
    }

    private static func fetch(url: String, via: LuckgramProxyExitChecker.Socks?, completion: @escaping (String?) -> Void) {
        guard let u = URL(string: url) else {
            completion(nil)
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        if let via {
            if #available(iOS 17.0, *), let port = NWEndpoint.Port(rawValue: UInt16(clamping: via.port)) {
                var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(via.host), port: port))
                if !via.username.isEmpty {
                    proxy.applyCredential(username: via.username, password: via.password)
                }
                config.proxyConfigurations = [proxy]
            } else {
                completion(nil)
                return
            }
        } else {
            config.connectionProxyDictionary = [:]
        }
        var request = URLRequest(url: u)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode / 100 == 2, let data, data.count <= LuckgramProxyImportLogic.maxBytes else {
                completion(nil)
                return
            }
            completion(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }

    /// "N 个代理 · 更新于 11-07 15:20".
    public static func subLine(_ s: Sub, zh: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        let when = s.updated > 0 ? f.string(from: Date(timeIntervalSince1970: s.updated)) : "—"
        return LuckgramProxyImportTexts(zh: zh).subLine(s.keys.count, when)
    }
}

/// Texts of specs#118 (Chinese or English, the Luckgram language rule). Same as Android `ProxyImport.T`.
public struct LuckgramProxyImportTexts {
    public let zh: Bool

    public init(zh: Bool) {
        self.zh = zh
    }

    private func t(_ z: String, _ e: String) -> String { zh ? z : e }

    public var scanRow: String { t("扫码添加代理", "Scan QR Code") }
    public var linkRow: String { t("输入链接或订阅地址", "Add from Link or Subscription") }
    public var subsHeader: String { t("订阅", "SUBSCRIPTIONS") }
    public var scanHint: String { t("扫描代理二维码或订阅地址二维码", "Scan a proxy or subscription QR code") }
    public var inputTitle: String { t("添加代理", "Add Proxy") }
    public var inputMessage: String { t("粘贴代理链接（tg://socks、t.me/proxy、socks5://、vless://、vmess://、trojan://、ss://）或 mihomo / Clash 订阅地址。", "Paste a proxy link (tg://socks, t.me/proxy, socks5://, vless://, vmess://, trojan://, ss://) or a mihomo / Clash subscription URL.") }
    public var inputHint: String { t("链接或订阅地址", "Link or subscription URL") }
    public var add: String { t("添加", "Add") }
    public var added: String { t("已添加代理", "Proxy added") }
    public var alreadyAdded: String { t("这个代理已在列表里", "This proxy is already in the list") }
    public var unknownTitle: String { t("无法识别", "Not recognized") }
    public var unknown: String { t("无法识别的代理链接。支持 tg://socks、t.me/proxy、socks5://、vless://、vmess://、trojan://、ss:// 链接和 mihomo / Clash 订阅地址。", "This is not a proxy link. Supported: tg://socks, t.me/proxy, socks5://, vless://, vmess://, trojan://, ss:// links and mihomo / Clash subscription URLs.") }
    public var importTitle: String { t("导入订阅", "Import Subscription") }
    public var refreshTitle: String { t("刷新订阅", "Refresh Subscription") }
    public var downloadFailed: String { t("下载订阅失败，请检查地址和网络后重试。", "Could not download the subscription. Check the URL and your connection, then try again.") }
    public var refresh: String { t("刷新", "Refresh") }
    public var delete: String { t("删除订阅", "Delete Subscription") }
    public var deleteTitle: String { t("删除订阅？", "Delete subscription?") }
    public var cancel: String { t("取消", "Cancel") }
    public var ok: String { t("好", "OK") }

    public func deleteMessage(_ n: Int) -> String {
        t("将同时删除由这个订阅导入的 \(n) 个代理。手动添加的代理不受影响。", "The \(n) proxies imported from it will be removed too. Proxies you added yourself stay.")
    }

    public func subLine(_ n: Int, _ when: String) -> String {
        t("\(n) 个代理 · 更新于 \(when)", "\(n) \(n == 1 ? "proxy" : "proxies") · updated \(when)")
    }

    /// `coreProblem`: why Xray nodes were skipped (core off / missing), nil when they were not.
    public func result(total: Int, added: Int, removed: Int, skipped: Int, coreProblem: String? = nil) -> String {
        var s = t("订阅里有 \(total) 个可用代理：新增 \(added) 个", "\(total) usable \(total == 1 ? "proxy" : "proxies"): \(added) added")
        if removed > 0 { s += t("，移除 \(removed) 个", ", \(removed) removed") }
        s += t("。", ".")
        if skipped > 0 {
            if let coreProblem {
                s += "\n\n" + t("跳过 \(skipped) 个节点：\(coreProblem)。", "Skipped \(skipped) \(skipped == 1 ? "entry" : "entries"): \(coreProblem).")
            } else {
                s += "\n\n" + t("跳过 \(skipped) 个不支持的节点（支持 SOCKS5、MTProto、VLESS、VMess、Trojan、Shadowsocks；Hysteria、TUIC 等用不了，未加密的 VLESS / Trojan 内核也不支持）。",
                                "Skipped \(skipped) unsupported \(skipped == 1 ? "entry" : "entries") (supported: SOCKS5, MTProto, VLESS, VMess, Trojan, Shadowsocks; not Hysteria, TUIC and others, nor unencrypted VLESS / Trojan).")
            }
        }
        return s
    }
}
