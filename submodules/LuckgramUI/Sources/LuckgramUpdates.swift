import Foundation
import UIKit
import SwiftSignalKit

/// Update check (task S5, luckgram-specs#30, specs/server/S5-version.md item 3):
/// - `GET /v1/version` when the app comes to the foreground, at most once an hour (the last
///   successful check is kept on the device, so restarts do not count) and right away after the
///   installed version or build changed;
/// - a newer version shows "有新版本 x.y.z · 更新" on top of Settings (PeerInfoSettingsItems),
///   which opens the download link;
/// - below the minimum version a full-screen page with only the Update button covers the app
///   (presented by SharedAccountContext) until the installed version is not below the minimum.
/// Only device state is sent (platform, version, build), so no AI consent is needed.
public final class LuckgramUpdates {
    public static let shared = LuckgramUpdates()

    private static let infoKey = "update_info"
    private static let lastCheckKey = "update_last_check"
    /// LuckgramUpdateLogic.appId of the app that made the last successful check.
    private static let lastCheckAppKey = "update_last_check_app"

    private var lastFailure: Date?
    private var inFlight = false
    private let fetch = MetaDisposable()
    private let statePromise: ValuePromise<LuckgramUpdateLogic.State>

    private init() {
        self.statePromise = ValuePromise(LuckgramUpdateLogic.State.hidden, ignoreRepeated: true)
        self.statePromise.set(self.state)
    }

    public static var appVersion: String {
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// CFBundleVersion = the build number build.yml publishes; 0 if not a number.
    public static var appBuild: Int64 {
        return Int64((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "") ?? 0
    }

    /// The cached answer evaluated against the running version.
    public var state: LuckgramUpdateLogic.State {
        let info = LuckgramUpdateLogic.deserialize(LuckgramSettings.shared.string(LuckgramUpdates.infoKey, default: nil))
        return LuckgramUpdateLogic.evaluate(info, current: LuckgramUpdates.appVersion, currentBuild: LuckgramUpdates.appBuild, chinese: LuckgramStrings.isChinese)
    }

    public var stateSignal: Signal<LuckgramUpdateLogic.State, NoError> {
        return self.statePromise.get()
    }

    /// "有新版本 x.y.z（build） · 更新".
    public static func rowText(_ state: LuckgramUpdateLogic.State) -> String {
        return LuckgramUpdateLogic.rowText(state, chinese: LuckgramStrings.isChinese)
    }

    /// specs#124: an unsigned IPA can't be installed from inside the app, so "Update" explains that
    /// the new version must be re-signed and offers the IPA (dl.luckgram.cc), the install guide and,
    /// unless updating is forced, "Later".
    public static func guideController(state: LuckgramUpdateLogic.State, force: Bool, openUrl: @escaping (String) -> Void) -> UIViewController {
        var message = LuckgramUpdateLogic.guideMessage(state, chinese: LuckgramStrings.isChinese)
        if !state.notes.isEmpty && !force {
            message += "\n\n" + state.notes
        }
        let alert = UIAlertController(title: LuckgramUpdateLogic.guideTitle(state, chinese: LuckgramStrings.isChinese), message: message, preferredStyle: .alert)
        for action in LuckgramUpdateLogic.guideActions(force: force) {
            switch action {
            case .download:
                alert.addAction(UIAlertAction(title: LuckgramStrings.pick("下载安装包", "Download package"), style: .default, handler: { _ in
                    if state.url.lowercased().hasPrefix("https://") {
                        openUrl(state.url)
                    }
                }))
            case .guide:
                alert.addAction(UIAlertAction(title: LuckgramStrings.pick("查看安装指南", "Installation guide"), style: .default, handler: { _ in
                    openUrl(LuckgramUpdateLogic.installGuideUrl(state.installUrl))
                }))
            case .later:
                alert.addAction(UIAlertAction(title: LuckgramStrings.pick("以后再说", "Later"), style: .cancel, handler: nil))
            }
        }
        return alert
    }

    /// Main queue.
    public func checkIfDue() {
        let last = LuckgramSettings.shared.int(LuckgramUpdates.lastCheckKey, default: 0)
        let lastSuccess: Date? = last > 0 ? Date(timeIntervalSince1970: TimeInterval(last)) : nil
        let checkedBy = LuckgramSettings.shared.string(LuckgramUpdates.lastCheckAppKey, default: nil) ?? ""
        let running = LuckgramUpdateLogic.appId(version: LuckgramUpdates.appVersion, build: LuckgramUpdates.appBuild)
        if self.inFlight || !LuckgramUpdateLogic.shouldCheck(now: Date(), lastSuccess: lastSuccess, lastFailure: self.lastFailure, checkedBy: checkedBy, running: running) {
            self.statePromise.set(self.state)
            return
        }
        self.inFlight = true
        let path = LuckgramUpdateLogic.path(platform: "ios", appVersion: LuckgramUpdates.appVersion, build: LuckgramUpdates.appBuild)
        self.fetch.set(LuckgramAI.shared.requestJSON(method: "GET", path: path).start(next: { [weak self] response in
            guard let self else {
                return
            }
            self.inFlight = false
            self.lastFailure = nil
            LuckgramSettings.shared.setString(LuckgramUpdates.infoKey, LuckgramUpdateLogic.serialize(LuckgramUpdateLogic.parse(response)))
            LuckgramSettings.shared.setInt(LuckgramUpdates.lastCheckKey, Int(Date().timeIntervalSince1970))
            LuckgramSettings.shared.setString(LuckgramUpdates.lastCheckAppKey, running)
            self.statePromise.set(self.state)
        }, error: { [weak self] _ in
            self?.inFlight = false
            self?.lastFailure = Date()
        }))
    }
}

/// The full-screen "must update" page: no close button, not dismissable by swipe.
public final class LuckgramForceUpdateController: UIViewController {
    private let state: LuckgramUpdateLogic.State
    private let openUrl: (String) -> Void

    public init(state: LuckgramUpdateLogic.State, openUrl: @escaping (String) -> Void) {
        self.state = state
        self.openUrl = openUrl
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
        self.isModalInPresentation = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground

        let title = UILabel()
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textAlignment = .center
        title.numberOfLines = 0
        title.text = LuckgramStrings.pick("需要更新", "Update required")

        let text = UILabel()
        text.font = .systemFont(ofSize: 16)
        text.textColor = .secondaryLabel
        text.textAlignment = .center
        text.numberOfLines = 0
        var body = LuckgramUpdateLogic.forceText(self.state, current: LuckgramUpdates.appVersion, currentBuild: LuckgramUpdates.appBuild, chinese: LuckgramStrings.isChinese)
        if !self.state.notes.isEmpty {
            body += "\n\n" + self.state.notes
        }
        text.text = body

        let button = UIButton(type: .system)
        button.setTitle(LuckgramStrings.pick("更新", "Update"), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.backgroundColor = self.view.tintColor
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        button.addTarget(self, action: #selector(self.updatePressed), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, text, button])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(32, after: text)
        stack.translatesAutoresizingMaskIntoConstraints = false

        self.view.addSubview(stack)
        let guide = self.view.safeAreaLayoutGuide
        let centerY = stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor)
        centerY.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -24),
            centerY,
            button.heightAnchor.constraint(equalToConstant: 50)
        ])
        // Long release notes shrink instead of pushing the button off screen.
        text.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @objc private func updatePressed() {
        if self.presentedViewController != nil {
            return
        }
        self.present(LuckgramUpdates.guideController(state: self.state, force: true, openUrl: self.openUrl), animated: true)
    }
}
