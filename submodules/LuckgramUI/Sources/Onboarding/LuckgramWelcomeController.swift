import Foundation
import UIKit
import AsyncDisplayKit
import Display
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
    private var alertShown = false

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
            self.showPrivacy(thenStart: false)
        }
    }

    private func start() {
        if LuckgramWelcomeLogic.shouldAskPrivacy(accepted: LuckgramWelcomeController.isAccepted) {
            self.showPrivacy(thenStart: true)
            return
        }
        if LuckgramWelcomeLogic.shouldShowSteps(onboarded: LuckgramSettings.shared.bool(LuckgramWelcomeLogic.onboardedKey, default: false)) {
            // Steps on top of this page: back from the first step returns here.
            let getStarted = self.getStarted
            self.push(LuckgramOnboardingController(finish: {
                LuckgramSettings.shared.setBool(LuckgramWelcomeLogic.onboardedKey, true)
                getStarted()
            }))
        } else {
            self.getStarted()
        }
    }

    private func showPrivacy(thenStart: Bool) {
        if self.alertShown {
            return
        }
        self.alertShown = true
        LuckgramPrivacyAlert.show(sharedContext: self.sharedContext, updated: false, openUrl: self.openUrl, present: { [weak self] c in
            self?.present(c, in: .window(.root))
        }, onAccepted: { [weak self] in
            guard let self else {
                return
            }
            self.alertShown = false
            if thenStart {
                self.start()
            }
        })
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
