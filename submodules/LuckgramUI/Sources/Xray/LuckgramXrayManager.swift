import Foundation
import Darwin
import Security
import SwiftSignalKit

/// specs#119: the Xray nodes of this device and the in-process core that serves them.
///
/// Each node is a SOCKS5 proxy at `127.0.0.1:<localPort>` in Telegram's own proxy list, so
/// Telegram connects, pings and switches as usual. One Xray instance has a loopback SOCKS5 inbound
/// per node (username / password random per install) routed to that node's outbound. No
/// NetworkExtension: only Luckgram's own traffic. Same behaviour as Android `XrayManager`.
///
/// The core (`LuckgramXray.framework`, built in CI) is linked by the app binary only and found with
/// `dlsym`, so extensions and builds without it simply report "core not included".
///
/// Node data is kept in the Keychain (this device only), survives logout like Telegram's proxies
/// and is dropped on a fresh install.
public final class LuckgramXrayManager {
    public static let featureKey = "xray_core"
    public static let localHost = "127.0.0.1"
    public static let user = "lg"

    public static let shared = LuckgramXrayManager()

    public struct Rec: Codable, Equatable {
        public var link: String
        public var proto: String
        public var host: String
        public var port: Int
        public var name: String
        public var localPort: Int
        public var outbound: String

        public var key: String { LuckgramXrayLogic.key(link: link) }

        private var hostPort: String { (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }

        /// The name, or host:port when there is none.
        public var title: String { name.isEmpty ? hostPort : name }

        /// "VLESS · host:port".
        public var detail: String { LuckgramXrayLogic.label(proto) + " · " + hostPort }
    }

    private struct Stored: Codable {
        var pass: String
        var base: Int
        var nodes: [Rec]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "luckgram-xray")
    private var stored: Stored?
    private var running = false
    private var lastError: String?
    private var switchDisposable: Disposable?

    /// Called on the main queue after the core was (re)started or stopped.
    public var onStateChanged: (() -> Void)?

    private init() {
    }

    // MARK: - core

    private typealias InvokeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias FreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private static let core: (invoke: InvokeFn, free: FreeFn)? = {
        // App only: an extension never runs the core.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        var handle = dlopen(nil, RTLD_NOW)
        var invoke = dlsym(handle, "CGoInvoke")
        var free = dlsym(handle, "CGoFree")
        if invoke == nil || free == nil, let dir = Bundle.main.privateFrameworksPath {
            handle = dlopen(dir + "/LuckgramXray.framework/LuckgramXray", RTLD_NOW)
            if handle != nil {
                invoke = dlsym(handle, "CGoInvoke")
                free = dlsym(handle, "CGoFree")
            }
        }
        guard let invoke, let free else { return nil }
        return (unsafeBitCast(invoke, to: InvokeFn.self), unsafeBitCast(free, to: FreeFn.self))
    }()

    public static var coreAvailable: Bool { core != nil }

    /// `{"success":..,"data":..,"error":..}` of libXray's `Invoke`; never throws.
    private static func call(_ method: String, _ payload: [String: Any]? = nil) -> [String: Any] {
        guard let core else { return ["success": false, "error": "core not included"] }
        var req: [String: Any] = ["apiVersion": 3, "method": method]
        if let payload { req["payload"] = payload }
        guard let data = try? JSONSerialization.data(withJSONObject: req), let text = String(data: data, encoding: .utf8) else {
            return ["success": false, "error": "invalid request"]
        }
        let result: String? = text.withCString { ptr -> String? in
            guard let out = core.invoke(UnsafeMutablePointer(mutating: ptr)) else { return nil }
            defer { core.free(out) }
            return String(cString: out)
        }
        guard let result, let obj = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else {
            return ["success": false, "error": "empty response"]
        }
        return obj
    }

    /// The Xray outbound for one canonical share link, or nil when libXray cannot build it.
    static func outbound(for link: String) -> String? {
        let r = call("convertShareLinksToXrayJson", ["text": link])
        guard (r["success"] as? Bool) == true, let d = r["data"],
              let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) else { return nil }
        return LuckgramXrayLogic.firstOutbound(text)
    }

    private static func shorten(_ s: String) -> String {
        let line = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    // MARK: - state

    /// The switch in Luckgram features and the core being part of this build.
    public var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramXrayManager.featureKey) && LuckgramXrayManager.coreAvailable
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Why a node cannot be used right now, or nil when the core is running.
    public func problem(zh: Bool) -> String? {
        let t = LuckgramXrayTexts(zh: zh)
        if !LuckgramXrayManager.coreAvailable { return t.notIncluded }
        if !LuckgramSettings.shared.isEnabled(LuckgramXrayManager.featureKey) { return t.switchedOff }
        lock.lock(); defer { lock.unlock() }
        if running { return nil }
        return lastError.map { t.notRunning($0) } ?? t.starting
    }

    /// `problem(zh:)` for one node; first that the core refuses it.
    public func problem(for rec: Rec, zh: Bool) -> String? {
        if LuckgramXrayLogic.refusedByCore(rec.outbound) { return LuckgramXrayTexts(zh: zh).unencrypted }
        return problem(zh: zh)
    }

    /// Why `register` gave nothing for this node.
    public func refusedText(for node: LuckgramXrayLogic.Node?, zh: Bool) -> String {
        let t = LuckgramXrayTexts(zh: zh)
        if let node, let outbound = LuckgramXrayManager.outbound(for: node.link), LuckgramXrayLogic.refusedByCore(outbound) {
            return t.unencrypted
        }
        return t.unavailable
    }

    public var nodes: [Rec] {
        lock.lock(); defer { lock.unlock() }
        return load().nodes
    }

    public var password: String {
        lock.lock(); defer { lock.unlock() }
        return load().pass
    }

    /// The node behind a SOCKS5 proxy of Telegram's list, or nil when it is an ordinary proxy.
    public func node(host: String, port: Int, username: String?) -> Rec? {
        guard host == LuckgramXrayManager.localHost, username == LuckgramXrayManager.user else { return nil }
        lock.lock(); defer { lock.unlock() }
        return load().nodes.first(where: { $0.localPort == port })
    }

    // MARK: - changes

    /// Adds (or finds) the node for a share link; returns its local port, or nil when libXray
    /// cannot build it. Call `apply()` after a batch.
    public func register(_ node: LuckgramXrayLogic.Node) -> Int? {
        lock.lock()
        var s = load()
        if let i = s.nodes.firstIndex(where: { $0.key == node.key }) {
            if s.nodes[i].name != node.name {
                s.nodes[i].name = node.name
                s.nodes[i].link = node.link
                save(s)
            }
            let port = s.nodes[i].localPort
            lock.unlock()
            return port
        }
        lock.unlock()
        // refusedText(for:) says why.
        guard let outbound = LuckgramXrayManager.outbound(for: node.link), !LuckgramXrayLogic.refusedByCore(outbound) else { return nil }
        lock.lock(); defer { lock.unlock() }
        s = load()
        guard let port = LuckgramXrayLogic.pickPorts(base: s.base, used: Set(s.nodes.map { $0.localPort }), count: 1).first else { return nil }
        s.nodes.append(Rec(link: node.link, proto: node.proto, host: node.host, port: node.port, name: node.name, localPort: port, outbound: outbound))
        save(s)
        return port
    }

    /// Drops nodes whose proxy is no longer in Telegram's list (`livePorts`: the ports of its
    /// 127.0.0.1 proxies with our username) and restarts the core when something was dropped or
    /// `forceApply` is set.
    public func reconcile(livePorts: Set<Int>, forceApply: Bool) {
        lock.lock()
        var s = load()
        let before = s.nodes.count
        s.nodes.removeAll(where: { !livePorts.contains($0.localPort) })
        let changed = s.nodes.count != before
        if changed { save(s) }
        lock.unlock()
        if changed || forceApply { apply() }
    }

    /// Restarts the core with the current nodes (stops it when there are none or it is off).
    public func apply(completion: (() -> Void)? = nil) {
        queue.async {
            self.applyNow()
            DispatchQueue.main.async {
                completion?()
                self.onStateChanged?()
            }
        }
    }

    private func applyNow() {
        lock.lock()
        let s = load()
        lock.unlock()
        _ = LuckgramXrayManager.call("stopXray")
        var error: String?
        var ok = false
        if isEnabled && !s.nodes.isEmpty {
            // A node the core refuses (added before #125) stays in the list, marked, but isn't run:
            // one such outbound would stop every node.
            let runs = s.nodes.filter { !LuckgramXrayLogic.refusedByCore($0.outbound) }.map { LuckgramXrayLogic.Run(localPort: $0.localPort, outboundJson: $0.outbound) }
            // debugging only: `defaults write com.luckgram.messenger LuckgramXrayLogLevel info`
            let level = UserDefaults.standard.string(forKey: "LuckgramXrayLogLevel") ?? "warning"
            if let config = LuckgramXrayLogic.buildConfig(runs, user: LuckgramXrayManager.user, password: s.pass, logLevel: level) {
                let r = LuckgramXrayManager.call("runXray", ["xrayJson": config])
                ok = (r["success"] as? Bool) == true
                if !ok { error = LuckgramXrayManager.shorten((r["error"] as? String) ?? "unknown error") }
            } else {
                error = "invalid config"
            }
        }
        lock.lock()
        running = ok
        lastError = error
        lock.unlock()
    }

    /// At launch, before Telegram connects: starts the core synchronously when there are nodes.
    /// iOS can drop a suspended app's listening sockets, so the app also calls this when it
    /// returns to the foreground.
    public func start() {
        if switchDisposable == nil {
            // the switch in Luckgram features starts / stops the core
            switchDisposable = (LuckgramSettings.shared.changes |> filter { $0 == nil || $0 == LuckgramXrayManager.featureKey }).start(next: { [weak self] _ in
                self?.apply()
            })
        }
        lock.lock()
        let any = !load().nodes.isEmpty
        lock.unlock()
        guard any || isRunning else { return }
        queue.sync { self.applyNow() }
        DispatchQueue.main.async { self.onStateChanged?() }
    }

    // MARK: - storage (caller holds the lock)

    private func load() -> Stored {
        if let stored { return stored }
        var s: Stored
        if let json = LuckgramKeychain.get(account: LuckgramKeychain.xrayNodesAccount),
           let decoded = try? JSONDecoder().decode(Stored.self, from: Data(json.utf8)), !decoded.pass.isEmpty, decoded.base >= 20000 {
            s = decoded
        } else {
            var bytes = [UInt8](repeating: 0, count: 18)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            s = Stored(pass: LuckgramXrayLogic.base64UrlNoPad(Data(bytes)), base: 20000 + Int.random(in: 0..<35000), nodes: [])
            save(s)
        }
        stored = s
        return s
    }

    private func save(_ s: Stored) {
        stored = s
        if let data = try? JSONEncoder().encode(s), let json = String(data: data, encoding: .utf8) {
            LuckgramKeychain.set(account: LuckgramKeychain.xrayNodesAccount, value: json)
        }
    }
}

/// Texts of specs#119 (Chinese or English). Same as Android `XrayManager.T`.
public struct LuckgramXrayTexts {
    public let zh: Bool

    public init(zh: Bool) {
        self.zh = zh
    }

    private func t(_ z: String, _ e: String) -> String { zh ? z : e }

    public var notIncluded: String { t("这个版本没有内置代理内核", "This build has no built-in proxy core") }
    public var switchedOff: String { t("内置代理内核已关闭（设置 → Luckgram 功能）", "Built-in proxy core is off (Settings → Luckgram features)") }
    public var starting: String { t("内核启动中…", "Starting core…") }
    public func notRunning(_ why: String) -> String { t("内核未运行：", "Core not running: ") + why }
    public var copyLink: String { t("复制分享链接", "Copy Share Link") }
    public var linkCopied: String { t("链接已复制", "Link copied") }
    public var delete: String { t("删除代理", "Delete Proxy") }
    public var unavailable: String { t("这个节点现在用不了", "This node can't be used now") }
    public var unencrypted: String { t("未加密的 VLESS / Trojan 节点内核不支持，需要 TLS 或 Reality", "The core doesn't run unencrypted VLESS / Trojan nodes: TLS or Reality is needed") }
}
