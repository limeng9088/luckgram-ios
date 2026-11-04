import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import PresentationDataUtils

/// specs#76: first-launch welcome page shown instead of Telegram's splash while no account is
/// logged in. Dark page with a tile pattern (no logo), "Welcome to" + Luckgram, a short intro and a "Get Started"
/// button. The privacy policy alert opens by itself until the user taps Continue; Get Started then
/// goes on to the usual phone-number login (`getStarted`).
public final class LuckgramWelcomeController: ViewController {
    private let sharedContext: SharedAccountContext
    private let openUrl: (String) -> Void
    private let getStarted: () -> Void
    private let texts = LuckgramWelcomeLogic.Texts(zh: LuckgramStrings.isChinese)
    private var asked = false
    private weak var privacyAlert: ViewController?

    public static var isAccepted: Bool {
        return LuckgramPrivacyAlert.isAccepted
    }

    public init(sharedContext: SharedAccountContext, openUrl: @escaping (String) -> Void, getStarted: @escaping () -> Void) {
        self.sharedContext = sharedContext
        self.openUrl = openUrl
        self.getStarted = getStarted
        super.init(navigationBarPresentationData: nil)
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.statusBar.statusBarStyle = .White
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var welcomeView: LuckgramWelcomeView {
        return self.displayNode.view as! LuckgramWelcomeView
    }

    override public func loadDisplayNode() {
        let texts = self.texts
        self.displayNode = ASDisplayNode(viewBlock: {
            return LuckgramWelcomeView(texts: texts)
        }, didLoad: nil)
        self.displayNodeDidLoad()
        self.welcomeView.startPressed = { [weak self] in
            self?.start()
        }
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.welcomeView.safeInsets = UIEdgeInsets(top: layout.statusBarHeight ?? 0.0, left: layout.safeInsets.left, bottom: max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom), right: layout.safeInsets.right)
        self.welcomeView.setNeedsLayout()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !self.asked && LuckgramWelcomeLogic.shouldAskPrivacy(accepted: LuckgramWelcomeController.isAccepted) {
            self.asked = true
            // After the first layout pass: on the first setViewControllers of the auth flow the
            // page may not be in a window yet and an alert presented now is dropped.
            DispatchQueue.main.async { [weak self] in
                guard let self, !LuckgramWelcomeController.isAccepted else {
                    return
                }
                self.showPrivacy(thenStart: false)
            }
        }
    }

    /// specs#76 P0: "Get Started" always responds. The alert is shown again unless it is really
    /// on screen (presenting can silently do nothing while this page has no window), and login
    /// opens directly when the steps can't be pushed.
    private func start() {
        let action = LuckgramWelcomeLogic.startAction(
            accepted: LuckgramWelcomeController.isAccepted,
            privacyOnScreen: self.privacyOnScreen,
            onboarded: LuckgramSettings.shared.bool(LuckgramWelcomeLogic.onboardedKey, default: false),
            canPush: self.navigationController is NavigationController
        )
        LuckgramWelcomeController.log("start", "\(action) window=\(self.window != nil) nav=\(self.navigationController is NavigationController)")
        switch action {
        case .showPrivacy:
            self.showPrivacy(thenStart: true)
        case .waitForPrivacy:
            break
        case .showSteps:
            // Steps on top of this page: back from the first step returns here.
            let getStarted = self.getStarted
            let steps = LuckgramOnboardingController(finish: {
                LuckgramSettings.shared.setBool(LuckgramWelcomeLogic.onboardedKey, true)
                getStarted()
            })
            self.push(steps)
            // The push waits for the steps page to be ready; if this page is still on top a moment
            // later it didn't happen (or was replaced), so go on to login instead of doing nothing.
            Queue.mainQueue().after(1.5, { [weak self, weak steps] in
                guard let self, let nav = self.navigationController, nav.viewControllers.last === self else {
                    return
                }
                if let steps, nav.viewControllers.contains(where: { $0 === steps }) {
                    return
                }
                LuckgramWelcomeController.log("steps", "push-failed")
                self.getStarted()
            })
        case .login:
            self.getStarted()
        }
    }

    private var privacyOnScreen: Bool {
        guard let alert = self.privacyAlert, alert.isNodeLoaded else {
            return false
        }
        return alert.displayNode.view.window != nil
    }

    /// `retry`: 0 for a tap or the first automatic show, else which automatic re-show this is.
    private func showPrivacy(thenStart: Bool, retry: Int = 0) {
        if self.privacyOnScreen {
            return
        }
        // An alert that never appeared or was removed some other way: drop it and show a new one.
        self.privacyAlert?.dismiss()
        self.privacyAlert = nil
        LuckgramPrivacyAlert.show(sharedContext: self.sharedContext, updated: false, openUrl: self.openUrl, present: { [weak self] c in
            guard let self else {
                return
            }
            self.privacyAlert = c
            if let window = self.window {
                window.present(c, on: .root, blockInteraction: false, completion: {})
            } else if let window = self.sharedContext.mainWindow {
                LuckgramWelcomeController.log("privacy", "no-window-fallback")
                window.present(c, on: .root)
            } else {
                LuckgramWelcomeController.log("privacy", "no-window")
            }
        }, onAccepted: { [weak self] in
            guard let self else {
                return
            }
            self.privacyAlert = nil
            LuckgramWelcomeController.log("privacy", "accepted")
            if thenStart {
                self.start()
            }
        })
        // Check the alert really came up; if not, the next tap (or this retry) shows it again.
        Queue.mainQueue().after(1.0, { [weak self] in
            guard let self, !LuckgramWelcomeController.isAccepted, !self.privacyOnScreen else {
                return
            }
            LuckgramWelcomeController.log("privacy", "not-on-screen window=\(self.window != nil) retry=\(retry)")
            // At most maxPrivacyRetries automatic re-shows; after that the next tap tries again.
            if self.window != nil && LuckgramWelcomeLogic.shouldRetryPrivacy(retry: retry + 1) {
                self.showPrivacy(thenStart: false, retry: retry + 1)
            }
        })
    }

    private static func log(_ step: String, _ detail: String) {
        var e = LuckgramDiagLog.Entry()
        e.timeMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.feature = "welcome"
        e.target = step
        e.failure = detail
        LuckgramNet.shared.log(e)
    }
}

/// Dark page: rounded tiles drawn in code (no image assets, no logo), texts, white button.
private final class LuckgramWelcomeView: UIView {
    var startPressed: (() -> Void)?
    var safeInsets: UIEdgeInsets = .zero

    private let tiles = LuckgramWelcomeTilesView()
    private let fade = CAGradientLayer()
    private let welcomeTo = UILabel()
    private let name = UILabel()
    private let intro = UILabel()
    private let button = UIButton(type: .custom)

    init(texts: LuckgramWelcomeLogic.Texts) {
        super.init(frame: .zero)
        self.backgroundColor = .black
        self.addSubview(self.tiles)
        self.fade.colors = [UIColor.black.withAlphaComponent(0.0).cgColor, UIColor.black.cgColor]
        self.layer.addSublayer(self.fade)


        self.welcomeTo.text = texts.welcomeTo
        self.welcomeTo.textColor = UIColor(rgb: 0x8E8E93)
        self.welcomeTo.font = UIFont.systemFont(ofSize: 16.0)
        self.welcomeTo.textAlignment = .center
        self.addSubview(self.welcomeTo)

        self.name.text = texts.appName
        self.name.textColor = .white
        self.name.font = UIFont.systemFont(ofSize: 42.0)
        self.name.textAlignment = .center
        self.addSubview(self.name)

        self.intro.text = texts.intro
        self.intro.textColor = .white
        self.intro.font = UIFont.systemFont(ofSize: 17.0)
        self.intro.textAlignment = .center
        self.intro.numberOfLines = 0
        self.addSubview(self.intro)

        self.button.backgroundColor = .white
        self.button.layer.cornerRadius = 26.0
        self.button.setTitle(texts.getStarted, for: .normal)
        self.button.setTitleColor(.black, for: .normal)
        self.button.setTitleColor(UIColor(white: 0.3, alpha: 1.0), for: .highlighted)
        self.button.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
        self.addSubview(self.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func buttonPressed() {
        self.startPressed?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        let side: CGFloat = 24.0
        let width = min(size.width, 520.0)
        let left = floor((size.width - width) / 2.0)

        self.tiles.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height * 0.56)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.fade.frame = CGRect(x: 0.0, y: size.height * 0.36, width: size.width, height: size.height * 0.2)
        CATransaction.commit()

        let buttonHeight: CGFloat = 52.0
        let buttonY = size.height - max(self.safeInsets.bottom, 16.0) - 24.0 - buttonHeight
        self.button.frame = CGRect(x: left + side, y: buttonY, width: width - side * 2.0, height: buttonHeight)

        let introSize = self.intro.sizeThatFits(CGSize(width: width - side * 2.0, height: .greatestFiniteMagnitude))
        let introY = buttonY - 36.0 - introSize.height
        self.intro.frame = CGRect(x: left + side, y: introY, width: width - side * 2.0, height: ceil(introSize.height))
        let nameHeight: CGFloat = 52.0
        let nameY = introY - 10.0 - nameHeight
        self.name.frame = CGRect(x: left + side, y: nameY, width: width - side * 2.0, height: nameHeight)
        let welcomeY = nameY - 2.0 - 20.0
        self.welcomeTo.frame = CGRect(x: left + side, y: welcomeY, width: width - side * 2.0, height: 20.0)

        self.tiles.centerX = size.width / 2.0
        self.tiles.setNeedsDisplay()
    }
}

/// Rounded tiles at the top of the page; columns centred on the page.
private final class LuckgramWelcomeTilesView: UIView {
    var centerX: CGFloat = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        let tileSize: CGFloat = 112.0
        let gap: CGFloat = 18.0
        let step = tileSize + gap
        context.setFillColor(UIColor(rgb: 0x1C1C1E).cgColor)
        let startX = self.centerX - tileSize / 2.0 - step * ceil(self.centerX / step)
        var y = -tileSize * 0.55
        while y < self.bounds.height {
            var x = startX
            while x < self.bounds.width {
                context.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: y, width: tileSize, height: tileSize), cornerRadius: 30.0).cgPath)
                x += step
            }
            y += step
        }
        context.fillPath()
    }
}
