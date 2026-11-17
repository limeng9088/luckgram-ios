import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext

/// specs#98: called once a new login has finished. Offers the "Luckgram picks" folder when the
/// remote config switches it on, this Telegram account has not seen the offer and does not have
/// the folder yet. Silent on any error (bad link, network): the offer is optional.
public enum LuckgramFolderOffer {
    /// Set when the Pro page opens after login instead (onboarding "Subscribe"), so two pages don't stack.
    public static var skipNext = false

    public static func afterLogin(context: AccountContext, navigationController: @escaping () -> NavigationController?) {
        if self.skipNext {
            self.skipNext = false
            return
        }
        let config = LuckgramSettings.shared.remoteConfig
        let link = config.string(LuckgramFolderOfferLogic.linkKey, default: "") ?? ""
        let enabled = config.bool(LuckgramFolderOfferLogic.enabledKey, default: false)
        let userId = context.account.peerId.id._internalGetInt64Value()
        let key = LuckgramFolderOfferLogic.seenKey(userId: userId)
        guard LuckgramFolderOfferLogic.shouldCheck(enabled: enabled, link: link, seen: LuckgramSettings.shared.bool(key, default: false), userId: userId), let slug = LuckgramFolderOfferLogic.slug(link) else {
            return
        }
        let _ = (context.engine.peers.checkChatFolderLink(slug: slug)
        |> deliverOnMainQueue).start(next: { contents in
            guard LuckgramFolderOfferLogic.shouldOffer(alreadyAdded: contents.localFilterId != nil, peers: contents.peers.count) else {
                LuckgramSettings.shared.setBool(key, true)
                return
            }
            LuckgramSettings.shared.setBool(key, true)
            let page = LuckgramFolderOfferController(texts: LuckgramFolderOfferLogic.Texts(zh: LuckgramStrings.isChinese), add: {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                // t.me/addlist is handled in-app: Telegram's own "add folder" sheet, where the user confirms.
                context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: link, forceExternal: false, presentationData: presentationData, navigationController: navigationController(), dismissInput: {})
            })
            context.sharedContext.applicationBindings.presentNativeController(page)
        }, error: { _ in
        })
    }
}

/// Dark full-screen page: folder art, title, one line, "Add Luckgram Picks" and "No thanks".
final class LuckgramFolderOfferController: UIViewController {
    private let texts: LuckgramFolderOfferLogic.Texts
    private let add: () -> Void

    init(texts: LuckgramFolderOfferLogic.Texts, add: @escaping () -> Void) {
        self.texts = texts
        self.add = add
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black

        let art = LuckgramFolderOfferArtView()
        let title = UILabel()
        title.text = self.texts.title
        title.textColor = .white
        title.font = UIFont.systemFont(ofSize: 26.0, weight: .bold)
        title.textAlignment = .center
        title.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = self.texts.subtitle
        subtitle.textColor = UIColor(rgb: 0xAEAEB2)
        subtitle.font = UIFont.systemFont(ofSize: 16.0)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let addButton = UIButton(type: .system)
        addButton.setTitle(self.texts.add, for: .normal)
        addButton.setTitleColor(.black, for: .normal)
        addButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        addButton.backgroundColor = .white
        addButton.layer.cornerRadius = 26.0
        addButton.addTarget(self, action: #selector(self.addPressed), for: .touchUpInside)

        let skipButton = UIButton(type: .system)
        skipButton.setTitle(self.texts.skip, for: .normal)
        skipButton.setTitleColor(UIColor(rgb: 0xAEAEB2), for: .normal)
        skipButton.titleLabel?.font = UIFont.systemFont(ofSize: 16.0)
        skipButton.addTarget(self, action: #selector(self.skipPressed), for: .touchUpInside)

        for v in [art, title, subtitle, addButton, skipButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(v)
        }
        let guide = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            art.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            art.centerYAnchor.constraint(equalTo: guide.centerYAnchor, constant: -110.0),
            art.widthAnchor.constraint(equalToConstant: 240.0),
            art.heightAnchor.constraint(equalToConstant: 180.0),
            title.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 32.0),
            title.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28.0),
            title.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28.0),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10.0),
            subtitle.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32.0),
            subtitle.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32.0),
            skipButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16.0),
            skipButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24.0),
            skipButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24.0),
            skipButton.heightAnchor.constraint(equalToConstant: 44.0),
            addButton.bottomAnchor.constraint(equalTo: skipButton.topAnchor, constant: -8.0),
            addButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24.0),
            addButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24.0),
            addButton.heightAnchor.constraint(equalToConstant: 52.0)
        ])
    }

    @objc private func addPressed() {
        let add = self.add
        self.dismiss(animated: true, completion: {
            add()
        })
    }

    @objc private func skipPressed() {
        self.dismiss(animated: true, completion: nil)
    }
}

/// Drawn in code: a folder tile with a few coloured channel dots around it.
private final class LuckgramFolderOfferArtView: UIView {
    private static let colors: [UInt32] = [0x3E88F7, 0xFF9F0A, 0x34C759, 0xAF52DE, 0xFF375F]
    private static let dots: [(CGFloat, CGFloat, CGFloat)] = [(-0.36, -0.30, 20.0), (0.38, -0.26, 16.0), (-0.40, 0.30, 14.0), (0.36, 0.32, 22.0), (0.02, -0.46, 12.0)]

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        let cx = self.bounds.midX, cy = self.bounds.midY
        for (i, d) in Self.dots.enumerated() {
            ctx.setFillColor(UIColor(rgb: Self.colors[i % Self.colors.count]).cgColor)
            let x = cx + d.0 * self.bounds.width, y = cy + d.1 * self.bounds.height * 1.3
            ctx.fillEllipse(in: CGRect(x: x - d.2, y: y - d.2, width: d.2 * 2.0, height: d.2 * 2.0))
        }
        let tile = UIBezierPath(roundedRect: CGRect(x: cx - 44.0, y: cy - 44.0, width: 88.0, height: 88.0), cornerRadius: 26.0)
        UIColor(rgb: 0x1C1C1E).setFill()
        tile.fill()
        if let icon = UIImage(systemName: "folder.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 38.0, weight: .regular))?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            icon.draw(at: CGPoint(x: cx - icon.size.width / 2.0, y: cy - icon.size.height / 2.0))
        }
    }
}
