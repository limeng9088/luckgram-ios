import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

/// specs#76: onboarding steps between the welcome page and login: "n/N"
/// and a progress bar on top, a big title, text, an optional bold question, an illustration card
/// (built in code, made-up content) and a white button with a "not now" text button under it.
/// The two buttons write the step's feature switches; the Pro step (only while billing.enabled)
/// remembers "Subscribe" and the Pro page opens after login, since paying needs a Telegram account.
public final class LuckgramOnboardingController: ViewController {
    private let finish: () -> Void
    private let texts = LuckgramWelcomeLogic.Texts(zh: LuckgramStrings.isChinese)
    private let steps: [LuckgramWelcomeLogic.Step]
    private var index = 0
    private var cheapestPlan: LuckgramAccountLogic.Plan?
    private var plansDisposable: Disposable?

    public init(finish: @escaping () -> Void) {
        self.finish = finish
        self.steps = LuckgramWelcomeLogic.steps(billingEnabled: LuckgramSettings.shared.remoteConfig.bool("billing.enabled", default: false))
        super.init(navigationBarPresentationData: nil)
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.statusBar.statusBarStyle = .White
        if self.steps.contains(.pro) {
            self.plansDisposable = (LuckgramAI.shared.requestJSON(method: "GET", path: "/v1/billing/plans")
            |> deliverOnMainQueue).start(next: { [weak self] json in
                guard let self else {
                    return
                }
                let billing = LuckgramAccountLogic.parseBilling(json)
                self.cheapestPlan = billing.plans.min(by: { $0.stars < $1.stars })
                if self.isNodeLoaded, self.steps[self.index] == .pro, let plan = self.cheapestPlan {
                    self.pageView.setPrimaryTitle(self.texts.subscribe(stars: plan.stars, days: plan.days))
                }
            })
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.plansDisposable?.dispose()
    }

    private var pageView: LuckgramOnboardingView {
        return self.displayNode.view as! LuckgramOnboardingView
    }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode(viewBlock: {
            return LuckgramOnboardingView()
        }, didLoad: nil)
        self.displayNodeDidLoad()
        self.pageView.primaryPressed = { [weak self] in
            self?.choose(primary: true)
        }
        self.pageView.secondaryPressed = { [weak self] in
            self?.choose(primary: false)
        }
        self.bind(animated: false)
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.pageView.topInset = (layout.statusBarHeight ?? 0.0) + 14.0
        self.pageView.bottomInset = max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom) + 16.0
    }

    private func choose(primary: Bool) {
        let step = self.steps[self.index]
        if !primary && !LuckgramWelcomeLogic.hasSecondary(step) {
            return
        }
        for key in LuckgramWelcomeLogic.toggles(step) {
            LuckgramSettings.shared.setEnabled(key, primary)
        }
        if step == .pro {
            LuckgramSettings.shared.setBool(LuckgramWelcomeLogic.openProAfterLoginKey, primary)
        }
        if self.index + 1 < self.steps.count {
            self.index += 1
            self.bind(animated: true)
        } else {
            self.finish()
        }
    }

    private func bind(animated: Bool) {
        let step = self.steps[self.index]
        var primary = self.texts.primary(step)
        if step == .pro, let plan = self.cheapestPlan {
            primary = self.texts.subscribe(stars: plan.stars, days: plan.days)
        }
        self.pageView.show(
            progress: LuckgramWelcomeLogic.progress(index: self.index, total: self.steps.count),
            fraction: CGFloat(LuckgramWelcomeLogic.progressFraction(index: self.index, total: self.steps.count)),
            title: self.texts.title(step),
            body: self.texts.body(step),
            question: self.texts.question(step),
            card: LuckgramOnboardingCards.card(step, texts: self.texts),
            primary: primary,
            secondary: self.texts.secondary(step),
            animated: animated
        )
    }
}

private final class LuckgramOnboardingView: UIView {
    var primaryPressed: (() -> Void)?
    var secondaryPressed: (() -> Void)?
    var topInset: CGFloat = 20.0 {
        didSet {
            self.topConstraint?.constant = self.topInset
        }
    }
    var bottomInset: CGFloat = 16.0 {
        didSet {
            self.bottomConstraint?.constant = -self.bottomInset
        }
    }

    private let progressLabel = UILabel()
    private let progressBar = LuckgramOnboardingProgressView()
    private let content = UIStackView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let questionLabel = UILabel()
    private let cardContainer = UIView()
    private let primaryButton = UIButton(type: .custom)
    private let secondaryButton = UIButton(type: .custom)
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        self.backgroundColor = .black

        self.progressLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.progressLabel.textColor = UIColor(rgb: 0x8E8E93)
        let header = UIStackView(arrangedSubviews: [self.progressLabel, self.progressBar])
        header.axis = .horizontal
        header.spacing = 12.0
        header.alignment = .center
        self.progressBar.heightAnchor.constraint(equalToConstant: 6.0).isActive = true
        self.progressLabel.setContentHuggingPriority(.required, for: .horizontal)

        self.titleLabel.font = UIFont.systemFont(ofSize: 30.0)
        self.titleLabel.textColor = .white
        self.titleLabel.numberOfLines = 0
        self.bodyLabel.font = UIFont.systemFont(ofSize: 16.0)
        self.bodyLabel.textColor = UIColor(rgb: 0xE5E5EA)
        self.bodyLabel.numberOfLines = 0
        self.questionLabel.font = UIFont.boldSystemFont(ofSize: 16.0)
        self.questionLabel.textColor = .white
        self.questionLabel.numberOfLines = 0

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1.0), for: .vertical)
        spacer.setContentCompressionResistancePriority(UILayoutPriority(1.0), for: .vertical)
        for v in [self.titleLabel, self.bodyLabel, self.questionLabel, self.cardContainer] as [UIView] {
            v.setContentHuggingPriority(.required, for: .vertical)
            v.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        }
        self.content.axis = .vertical
        self.content.spacing = 10.0
        for v in [self.titleLabel, self.bodyLabel, self.questionLabel, spacer, self.cardContainer] {
            self.content.addArrangedSubview(v)
        }
        self.content.setCustomSpacing(14.0, after: self.bodyLabel)

        self.primaryButton.backgroundColor = .white
        self.primaryButton.layer.cornerRadius = 26.0
        self.primaryButton.setTitleColor(.black, for: .normal)
        self.primaryButton.setTitleColor(UIColor(white: 0.3, alpha: 1.0), for: .highlighted)
        self.primaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.primaryButton.addTarget(self, action: #selector(self.primaryTapped), for: .touchUpInside)
        self.secondaryButton.setTitleColor(UIColor(rgb: 0x8E8E93), for: .normal)
        self.secondaryButton.setTitleColor(UIColor(rgb: 0x636366), for: .highlighted)
        self.secondaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        self.secondaryButton.addTarget(self, action: #selector(self.secondaryTapped), for: .touchUpInside)

        for v in [header, self.content, self.primaryButton, self.secondaryButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(v)
        }
        let top = header.topAnchor.constraint(equalTo: self.topAnchor, constant: self.topInset)
        let bottom = self.secondaryButton.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -self.bottomInset)
        self.topConstraint = top
        self.bottomConstraint = bottom
        NSLayoutConstraint.activate([
            top,
            header.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20.0),
            header.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20.0),
            self.content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18.0),
            self.content.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20.0),
            self.content.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20.0),
            self.primaryButton.topAnchor.constraint(equalTo: self.content.bottomAnchor, constant: 20.0),
            self.primaryButton.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20.0),
            self.primaryButton.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20.0),
            self.primaryButton.heightAnchor.constraint(equalToConstant: 52.0),
            self.secondaryButton.topAnchor.constraint(equalTo: self.primaryButton.bottomAnchor, constant: 4.0),
            self.secondaryButton.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20.0),
            self.secondaryButton.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20.0),
            self.secondaryButton.heightAnchor.constraint(equalToConstant: 48.0),
            bottom
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func primaryTapped() {
        self.primaryPressed?()
    }

    @objc private func secondaryTapped() {
        self.secondaryPressed?()
    }

    func setPrimaryTitle(_ title: String) {
        self.primaryButton.setTitle(title, for: .normal)
    }

    func show(progress: String, fraction: CGFloat, title: String, body: String, question: String?, card: UIView, primary: String, secondary: String?, animated: Bool) {
        self.progressLabel.text = progress
        self.progressBar.setFraction(fraction, animated: animated)
        let apply = {
            self.titleLabel.text = title
            self.bodyLabel.text = body
            self.questionLabel.text = question
            self.questionLabel.isHidden = question == nil
            for v in self.cardContainer.subviews {
                v.removeFromSuperview()
            }
            card.translatesAutoresizingMaskIntoConstraints = false
            self.cardContainer.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: self.cardContainer.topAnchor),
                card.bottomAnchor.constraint(equalTo: self.cardContainer.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: self.cardContainer.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: self.cardContainer.trailingAnchor)
            ])
            self.primaryButton.setTitle(primary, for: .normal)
            self.secondaryButton.setTitle(secondary, for: .normal)
            self.secondaryButton.isHidden = secondary == nil
        }
        if !animated {
            apply()
            return
        }
        UIView.animate(withDuration: 0.14, delay: 0.0, options: [.curveEaseIn], animations: {
            self.content.alpha = 0.0
            self.content.transform = CGAffineTransform(translationX: -24.0, y: 0.0)
        }, completion: { _ in
            apply()
            self.content.transform = CGAffineTransform(translationX: 24.0, y: 0.0)
            UIView.animate(withDuration: 0.22, delay: 0.0, options: [.curveEaseOut], animations: {
                self.content.alpha = 1.0
                self.content.transform = .identity
            })
        })
    }
}

/// Rounded track with a white fill that slides to the current step.
private final class LuckgramOnboardingProgressView: UIView {
    private let fill = UIView()
    private var fraction: CGFloat = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = UIColor(rgb: 0x3A3A3C)
        self.layer.cornerRadius = 3.0
        self.clipsToBounds = true
        self.fill.backgroundColor = .white
        self.fill.layer.cornerRadius = 3.0
        self.addSubview(self.fill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFraction(_ value: CGFloat, animated: Bool) {
        self.fraction = value
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseOut], animations: {
                self.layoutFill()
            })
        } else {
            self.setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layoutFill()
    }

    private func layoutFill() {
        self.fill.frame = CGRect(x: 0.0, y: 0.0, width: max(self.bounds.height, self.bounds.width * self.fraction), height: self.bounds.height)
    }
}

/// Illustration cards built from plain views (made-up names and messages, no image assets).
private enum LuckgramOnboardingCards {
    static let card = UIColor(rgb: 0x1C1C1E)
    static let cardLight = UIColor(rgb: 0x2C2C2E)
    static let secondary = UIColor(rgb: 0x8E8E93)

    static func card(_ step: LuckgramWelcomeLogic.Step, texts: LuckgramWelcomeLogic.Texts) -> UIView {
        switch step {
        case .ai:
            return aiCard(texts)
        case .agents:
            return agentsCard(texts)
        case .summary:
            return summaryCard(texts)
        case .discover:
            return discoverCard(texts)
        case .pro:
            return proCard(texts)
        }
    }

    static func label(_ text: String, size: CGFloat, color: UIColor = .white, bold: Bool = false, center: Bool = false) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        l.textColor = color
        l.numberOfLines = 0
        l.textAlignment = center ? .center : .natural
        return l
    }

    static func stack(_ views: [UIView], spacing: CGFloat = 8.0, axis: NSLayoutConstraint.Axis = .vertical, alignment: UIStackView.Alignment = .fill) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = axis
        s.spacing = spacing
        s.alignment = alignment
        return s
    }

    /// `view` on a rounded background with padding.
    static func box(_ view: UIView, color: UIColor, radius: CGFloat, padding: UIEdgeInsets) -> UIView {
        let container = UIView()
        container.backgroundColor = color
        container.layer.cornerRadius = radius
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: padding.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding.bottom),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding.right)
        ])
        return container
    }

    static func panel(_ views: [UIView]) -> UIView {
        return box(stack(views, spacing: 8.0), color: card, radius: 22.0, padding: UIEdgeInsets(top: 14.0, left: 14.0, bottom: 14.0, right: 14.0))
    }

    static func bubble(_ text: String, outgoing: Bool) -> UIView {
        return box(label(text, size: 15.0), color: outgoing ? UIColor(rgb: 0x2F6EA5) : cardLight, radius: 16.0, padding: UIEdgeInsets(top: 8.0, left: 12.0, bottom: 8.0, right: 12.0))
    }

    static func avatar(_ letter: String, color: UIColor, size: CGFloat) -> UIView {
        let l = label(letter, size: size * 0.45, bold: true, center: true)
        l.backgroundColor = color
        l.layer.cornerRadius = size / 2.0
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: size).isActive = true
        l.heightAnchor.constraint(equalToConstant: size).isActive = true
        return l
    }

    static func aiCard(_ t: LuckgramWelcomeLogic.Texts) -> UIView {
        var quickRows: [UIView] = [label("✦ " + t.demoQuickTitle, size: 11.0, color: secondary)]
        for (i, reply) in t.demoQuickReplies.enumerated() {
            quickRows.append(label(reply, size: 15.0, bold: i == 0))
        }
        let quick = box(stack(quickRows, spacing: 6.0), color: UIColor(rgb: 0x3A3A3C), radius: 14.0, padding: UIEdgeInsets(top: 8.0, left: 12.0, bottom: 8.0, right: 12.0))
        let translated = box(stack([label(t.demoTranslated, size: 15.0), label("✦ " + t.demoTranslatedLabel, size: 11.0, color: UIColor(rgb: 0xB8D8FF))], spacing: 2.0), color: UIColor(rgb: 0x2F6EA5), radius: 16.0, padding: UIEdgeInsets(top: 8.0, left: 12.0, bottom: 8.0, right: 12.0))
        let header = stack([label(t.demoChatName, size: 15.0, bold: true, center: true), label(t.demoChatStatus, size: 12.0, color: secondary, center: true)], spacing: 0.0)
        return panel([
            header,
            stack([bubble(t.demoIncoming, outgoing: false)], alignment: .leading),
            stack([quick], alignment: .trailing),
            stack([translated], alignment: .trailing)
        ])
    }

    static func agentsCard(_ t: LuckgramWelcomeLogic.Texts) -> UIView {
        let colors = [UIColor(rgb: 0x5E5CE6), UIColor(rgb: 0x30B0C7), UIColor(rgb: 0xFF9F0A)]
        var rows: [UIView] = [label(t.demoAgentsTitle, size: 15.0, bold: true, center: true)]
        for (i, agent) in t.demoAgents.enumerated() {
            let text = stack([label(agent.0, size: 15.0, bold: true), label(agent.1, size: 13.0, color: secondary)], spacing: 2.0)
            let row = stack([avatar(String(agent.0.prefix(1)), color: colors[i % colors.count], size: 40.0), text], spacing: 10.0, axis: .horizontal, alignment: .center)
            rows.append(box(row, color: i == 0 ? UIColor(rgb: 0x3A3A3C) : cardLight, radius: 16.0, padding: UIEdgeInsets(top: 10.0, left: 10.0, bottom: 10.0, right: 12.0)))
        }
        return panel(rows)
    }

    static func summaryCard(_ t: LuckgramWelcomeLogic.Texts) -> UIView {
        var rows: [UIView] = [label(t.demoSummaryTitle, size: 15.0, bold: true, center: true), label(t.demoSummaryHead, size: 15.0, bold: true)]
        let colors = [UIColor.white, UIColor.white, UIColor(rgb: 0xAEAEB2), UIColor(rgb: 0x636366)]
        for (i, point) in t.demoSummaryPoints.enumerated() {
            rows.append(label("•  " + point, size: 15.0, color: colors[min(i, colors.count - 1)]))
        }
        return panel(rows)
    }

    static func discoverCard(_ t: LuckgramWelcomeLogic.Texts) -> UIView {
        let colors = [UIColor(rgb: 0x34C759), UIColor(rgb: 0xFF375F)]
        var rows: [UIView] = [label(t.demoNearbyTitle, size: 13.0, color: secondary)]
        for (i, person) in t.demoNearby.enumerated() {
            let distance = label(person.1, size: 13.0, color: secondary)
            distance.setContentHuggingPriority(.required, for: .horizontal)
            rows.append(stack([avatar(String(person.0.prefix(1)), color: colors[i % colors.count], size: 36.0), label(person.0, size: 15.0), distance], spacing: 10.0, axis: .horizontal, alignment: .center))
        }
        rows.append(label(t.demoSquareTitle, size: 13.0, color: secondary))
        let photo = LuckgramOnboardingSkyView()
        photo.heightAnchor.constraint(equalToConstant: 72.0).isActive = true
        rows.append(box(stack([photo, label(t.demoSquarePost + "   ♥ 24", size: 14.0)], spacing: 8.0), color: cardLight, radius: 16.0, padding: UIEdgeInsets(top: 10.0, left: 12.0, bottom: 10.0, right: 12.0)))
        return panel(rows)
    }

    static func proCard(_ t: LuckgramWelcomeLogic.Texts) -> UIView {
        let icons = ["✦", "⇄", "⭐"]
        let colors = [UIColor(rgb: 0x5E5CE6), UIColor(rgb: 0x0A84FF), UIColor(rgb: 0xFF9F0A)]
        var rows: [UIView] = []
        for (i, feature) in t.proFeatures.enumerated() {
            let icon = label(icons[i % icons.count], size: 16.0, center: true)
            icon.backgroundColor = colors[i % colors.count]
            icon.layer.cornerRadius = 10.0
            icon.clipsToBounds = true
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 34.0).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 34.0).isActive = true
            let text = stack([label(feature.0, size: 15.0, bold: true), label(feature.1, size: 13.0, color: secondary)], spacing: 2.0)
            rows.append(box(stack([icon, text], spacing: 12.0, axis: .horizontal, alignment: .top), color: card, radius: 16.0, padding: UIEdgeInsets(top: 12.0, left: 12.0, bottom: 12.0, right: 12.0)))
        }
        rows.append(label(t.proFootnote, size: 12.0, color: secondary, center: true))
        return stack(rows, spacing: 8.0)
    }
}

/// Sunset gradient standing in for a photo in the Square card.
private final class LuckgramOnboardingSkyView: UIView {
    override class var layerClass: AnyClass {
        return CAGradientLayer.self
    }

    init() {
        super.init(frame: .zero)
        let layer = self.layer as! CAGradientLayer
        layer.colors = [UIColor(rgb: 0x3A2C6E).cgColor, UIColor(rgb: 0xE8735A).cgColor, UIColor(rgb: 0xF7B267).cgColor]
        layer.cornerRadius = 12.0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
