import Foundation
import UIKit
import Display
import SwiftSignalKit

/// specs#87 (29) 需求 7: "Why not Pro for now?" after "Continue without Pro" on the onboarding Pro
/// step, once per device. Continue with an option posts `/v1/feedback/pro-skip` without waiting
/// (no retry, no message on failure) and goes to login; Skip or Continue with nothing picked sends
/// nothing. Only the option code and source are sent; no Telegram account exists yet.
/// Dark like the rest of the onboarding.
final class LuckgramProSkipSurveyView: UIView {
    /// Called once with the reason code to send, or nil.
    var done: ((String?) -> Void)?

    private let texts: LuckgramProPerks.Texts
    private var options: [LuckgramSurveyOptionView] = []
    private var choice: Int?
    private var finished = false
    private let accent = UIColor(rgb: 0x0A84FF)

    init(texts: LuckgramProPerks.Texts, topInset: CGFloat, bottomInset: CGFloat) {
        self.texts = texts
        super.init(frame: .zero)
        self.backgroundColor = .black

        let skip = UIButton(type: .custom)
        skip.setTitle(texts.surveySkip, for: .normal)
        skip.setTitleColor(UIColor(rgb: 0x8E8E93), for: .normal)
        skip.setTitleColor(UIColor(rgb: 0x636366), for: .highlighted)
        skip.titleLabel?.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
        skip.addTarget(self, action: #selector(self.skipTapped), for: .touchUpInside)

        let logo = UIImageView(image: LuckgramProSkipSurveyView.appIcon())
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 16.0
        logo.clipsToBounds = true

        let subtitle = UILabel()
        subtitle.text = texts.surveySubtitle
        subtitle.font = UIFont.systemFont(ofSize: 15.0)
        subtitle.textColor = UIColor(rgb: 0x8E8E93)
        subtitle.textAlignment = .center

        let title = UILabel()
        let titleText = NSMutableAttributedString(string: texts.surveyTitle, attributes: [.font: UIFont.boldSystemFont(ofSize: 26.0), .foregroundColor: UIColor.white])
        let range = (texts.surveyTitle as NSString).range(of: texts.surveyTitleAccent)
        if range.location != NSNotFound {
            titleText.addAttribute(.foregroundColor, value: self.accent, range: range)
        }
        title.attributedText = titleText
        title.numberOfLines = 0
        title.textAlignment = .center

        let optionStack = UIStackView()
        optionStack.axis = .vertical
        optionStack.spacing = 10.0
        for (i, text) in texts.surveyOptions.enumerated() {
            let b = LuckgramSurveyOptionView(text: text)
            b.tag = i
            b.heightAnchor.constraint(equalToConstant: 54.0).isActive = true
            b.addTarget(self, action: #selector(self.optionTapped(_:)), for: .touchUpInside)
            self.options.append(b)
            optionStack.addArrangedSubview(b)
        }

        let next = UIButton(type: .custom)
        next.setTitle(texts.surveyContinue, for: .normal)
        next.backgroundColor = .white
        next.layer.cornerRadius = 26.0
        next.setTitleColor(.black, for: .normal)
        next.setTitleColor(UIColor(white: 0.3, alpha: 1.0), for: .highlighted)
        next.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        next.addTarget(self, action: #selector(self.continueTapped), for: .touchUpInside)

        let middle = UIStackView(arrangedSubviews: [logo, subtitle, title, optionStack])
        middle.axis = .vertical
        middle.alignment = .fill
        middle.spacing = 8.0
        middle.setCustomSpacing(18.0, after: logo)
        middle.setCustomSpacing(24.0, after: title)

        for v in [skip, middle, next] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(v)
        }
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            skip.topAnchor.constraint(equalTo: self.topAnchor, constant: topInset),
            skip.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -16.0),
            skip.heightAnchor.constraint(equalToConstant: 44.0),
            logo.heightAnchor.constraint(equalToConstant: 72.0),
            middle.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20.0),
            middle.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20.0),
            middle.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            next.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20.0),
            next.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20.0),
            next.heightAnchor.constraint(equalToConstant: 52.0),
            next.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -bottomInset)
        ])
        self.updateOptions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func appIcon() -> UIImage? {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last {
            return UIImage(named: name)
        }
        return nil
    }

    private func updateOptions() {
        for (i, b) in self.options.enumerated() {
            let selected = i == self.choice
            b.layer.borderWidth = selected ? 2.0 : 0.0
            b.layer.borderColor = self.accent.cgColor
            b.label.text = (selected ? "✓  " : "") + self.texts.surveyOptions[i]
        }
    }

    @objc private func optionTapped(_ sender: LuckgramSurveyOptionView) {
        self.choice = sender.tag
        self.updateOptions()
    }

    @objc private func skipTapped() {
        self.finish(nil)
    }

    @objc private func continueTapped() {
        self.finish(LuckgramProPerks.surveyReason(self.choice))
    }

    private func finish(_ reason: String?) {
        if self.finished {
            return
        }
        self.finished = true
        self.done?(reason)
    }

    /// Fire and forget: login opens at once; failures are ignored.
    static func send(_ reason: String) {
        let _ = LuckgramAI.shared.requestJSON(method: "POST", path: LuckgramProPerks.surveyPath, body: ["reason": reason, "source": LuckgramProPerks.surveySource]).start(error: { _ in
        })
    }
}

/// One answer: a rounded dark row with left-aligned text.
final class LuckgramSurveyOptionView: UIControl {
    let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        self.backgroundColor = UIColor(rgb: 0x1C1C1E)
        self.layer.cornerRadius = 14.0
        self.label.text = text
        self.label.textColor = .white
        self.label.font = UIFont.systemFont(ofSize: 16.0)
        self.label.isUserInteractionEnabled = false
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.label)
        NSLayoutConstraint.activate([
            self.label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 18.0),
            self.label.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -18.0),
            self.label.centerYAnchor.constraint(equalTo: self.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            self.alpha = self.isHighlighted ? 0.7 : 1.0
        }
    }
}
