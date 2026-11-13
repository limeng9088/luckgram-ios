import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramPresentationData
import AccountContext
import AsyncDisplayKit
import WallpaperBackgroundNode
import TelegramCore

/// spec 18: the Luckgram AI assistant, a local chat page that looks like a Telegram chat. It is not
/// a Telegram bot or chat: nothing is sent to Telegram, requests go only to the AI gateway through
/// `LuckgramAI`. Extension points: `LuckgramAIRegistry`.
public final class LuckgramAIChatController: UIViewController, LuckgramAIChatHost, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiAssistant)
    }

    public static var isRowEnabled: Bool {
        return self.isEnabled && LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiAssistantRow)
    }

    /// From the chat list: reopens the most recent conversation, or a new one.
    public static func openLatest(context: AccountContext) {
        let store = LuckgramAIStore.shared(context: context)
        let latest = store.list().first(where: { $0.key == nil })
        self.present(context: context, conversation: latest ?? store.create(), prefill: nil)
    }

    /// A new conversation with `prefill` in the input field ("问 AI").
    public static func openNew(context: AccountContext, prefill: String?) {
        self.present(context: context, conversation: LuckgramAIStore.shared(context: context).create(), prefill: prefill)
    }

    /// Extension point: opens a stored conversation, e.g. one from `LuckgramAIStore.findOrCreate`.
    /// If the assistant is already on screen the conversation is pushed onto it.
    public static func open(context: AccountContext, conversationId: String, from host: LuckgramAIChatHost? = nil) {
        guard let conversation = LuckgramAIStore.shared(context: context).get(conversationId) else {
            return
        }
        if let navigation = host?.viewController.navigationController {
            navigation.pushViewController(LuckgramAIChatController(context: context, conversation: conversation, prefill: nil), animated: true)
        } else {
            self.present(context: context, conversation: conversation, prefill: nil)
        }
    }

    private static func present(context: AccountContext, conversation: LuckgramAIConversation, prefill: String?) {
        // The page is a native full-screen modal: Telegram alerts shown in the window would open
        // behind it, so the one-time AI consent (spec 00) is asked before the page opens.
        if !LuckgramAI.shared.hasConsent {
            let _ = (LuckgramAI.shared.requestConsent(context: context, present: { c in
                context.sharedContext.mainWindow?.present(c, on: .root)
            })
            |> deliverOnMainQueue).startStandalone(next: { granted in
                if granted {
                    self.present(context: context, conversation: conversation, prefill: prefill)
                }
            })
            return
        }
        let controller = LuckgramAIChatController(context: context, conversation: conversation, prefill: prefill)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        navigation.overrideUserInterfaceStyle = presentationData.theme.overallDarkAppearance ? .dark : .light
        context.sharedContext.mainWindow?.presentNative(navigation)
    }

    public let context: AccountContext
    public private(set) var conversation: LuckgramAIConversation
    private var prefill: String?
    private let theme: PresentationTheme

    private let wallpaper: TelegramWallpaper
    private var backgroundNode: WallpaperBackgroundNode?
    private let tableView = UITableView(frame: .zero, style: .plain)
    /// specs#101: welcome card with example questions while the conversation is empty.
    private let welcomeCard = UIView()
    /// specs#101: header entries (extension point 3) as Telegram-style pinned bars under the navigation bar.
    private let pinnedStack = UIStackView()
    private let quickScroll = UIScrollView()
    private let quickStack = UIStackView()
    private let inputPanel = UIView()
    private let inputView_ = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private var inputHeight: NSLayoutConstraint?

    private var streaming: LuckgramAIConversation.Message?
    private var requestDisposable: Disposable?
    private var storeDisposable: Disposable?

    public var viewController: UIViewController {
        return self
    }

    private init(context: AccountContext, conversation: LuckgramAIConversation, prefill: String?) {
        self.context = context
        self.conversation = conversation
        self.prefill = prefill
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.theme = presentationData.theme
        self.wallpaper = presentationData.chatWallpaper
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.requestDisposable?.dispose()
        self.storeDisposable?.dispose()
    }

    private var store: LuckgramAIStore {
        return LuckgramAIStore.shared(context: self.context)
    }

    // MARK: - View

    public override func viewDidLoad() {
        super.viewDidLoad()
        let theme = self.theme
        let service = serviceMessageColorComponents(theme: theme, wallpaper: self.wallpaper)

        // specs#101: the chat wallpaper behind everything, like a Telegram chat
        self.view.backgroundColor = theme.chatList.backgroundColor
        let backgroundNode = createWallpaperBackgroundNode(context: self.context, forChatDisplay: true)
        backgroundNode.update(wallpaper: self.wallpaper, animated: false)
        self.backgroundNode = backgroundNode
        self.view.addSubview(backgroundNode.view)

        // specs#101: Telegram navigation bar — back arrow, avatar + title, two plain icons
        self.navigationItem.titleView = self.makeTitleView()
        self.navigationItem.leftBarButtonItems = nil
        if self.navigationController?.viewControllers.first === self {
            let back = UIBarButtonItem(image: UIImage(systemName: "chevron.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.0, weight: .semibold)), style: .plain, target: self, action: #selector(self.closePressed))
            back.accessibilityLabel = LuckgramStrings.pick("返回", "Back")
            self.navigationItem.leftBarButtonItem = back
        }
        let newItem = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .plain, target: self, action: #selector(self.newPressed))
        newItem.accessibilityLabel = LuckgramStrings.pick("新对话", "New chat")
        let historyItem = UIBarButtonItem(image: UIImage(systemName: "clock.arrow.circlepath"), style: .plain, target: self, action: #selector(self.historyPressed))
        historyItem.accessibilityLabel = LuckgramStrings.pick("历史对话", "Chat history")
        self.navigationItem.rightBarButtonItems = [historyItem, newItem]
        if #available(iOS 26.0, *) {
            for item in [self.navigationItem.leftBarButtonItem, newItem, historyItem].compactMap({ $0 }) {
                item.hidesSharedBackground = true
            }
        }
        self.applyNavigationBarAppearance()

        // extension point 3: entries at the top of the page, as pinned bars
        self.pinnedStack.axis = .vertical
        for entry in LuckgramAIRegistry.headerEntries {
            self.pinnedStack.addArrangedSubview(self.makePinnedBar(entry))
        }
        self.pinnedStack.isHidden = self.pinnedStack.arrangedSubviews.isEmpty

        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.separatorStyle = .none
        self.tableView.backgroundColor = .clear
        self.tableView.keyboardDismissMode = .interactive
        self.tableView.allowsSelection = false
        self.tableView.contentInset = UIEdgeInsets(top: 6.0, left: 0.0, bottom: 6.0, right: 0.0)
        self.tableView.register(BubbleCell.self, forCellReuseIdentifier: "bubble")

        self.buildWelcomeCard(service: service)

        // spec 18 需求 3 + extension point 1: quick buttons, a scrollable row at the top of the input panel
        self.quickStack.axis = .horizontal
        self.quickStack.spacing = 8.0
        self.quickScroll.showsHorizontalScrollIndicator = false
        self.quickScroll.alwaysBounceHorizontal = true
        self.quickScroll.addSubview(self.quickStack)
        for action in LuckgramAIRegistry.quickActions {
            self.quickStack.addArrangedSubview(self.makeChip(title: LuckgramStrings.pick(action.title.0, action.title.1), icon: action.icon, action: { [weak self] in
                guard let self else {
                    return
                }
                action.action(self)
            }))
        }
        let hasQuick = !self.quickStack.arrangedSubviews.isEmpty

        // specs#101: Telegram message panel — panel color, hairline on top, rounded field with stroke
        self.inputPanel.backgroundColor = theme.chat.inputPanel.panelBackgroundColor
        // The panel ends at the keyboard guide (the safe area while the keyboard is down); without this the
        // wallpaper shows in the strip under it, next to the home indicator.
        let panelBottomFill = UIView()
        panelBottomFill.backgroundColor = theme.chat.inputPanel.panelBackgroundColor
        panelBottomFill.isUserInteractionEnabled = false
        panelBottomFill.translatesAutoresizingMaskIntoConstraints = false
        let panelSeparator = UIView()
        panelSeparator.backgroundColor = theme.chat.inputPanel.panelSeparatorColor
        panelSeparator.translatesAutoresizingMaskIntoConstraints = false
        self.inputPanel.addSubview(panelSeparator)
        self.inputView_.font = UIFont.systemFont(ofSize: 17.0)
        self.inputView_.textColor = theme.chat.inputPanel.inputTextColor
        self.inputView_.backgroundColor = theme.chat.inputPanel.inputBackgroundColor
        self.inputView_.layer.cornerRadius = 18.0
        self.inputView_.layer.borderWidth = 1.0 / UIScreen.main.scale
        self.inputView_.layer.borderColor = theme.chat.inputPanel.inputStrokeColor.cgColor
        self.inputView_.textContainerInset = UIEdgeInsets(top: 8.0, left: 8.0, bottom: 8.0, right: 8.0)
        self.inputView_.delegate = self
        self.inputView_.keyboardAppearance = theme.overallDarkAppearance ? .dark : .light
        self.inputView_.tintColor = theme.chat.inputPanel.panelControlAccentColor
        self.placeholderLabel.text = LuckgramStrings.pick("给 Luckgram AI 发消息", "Message Luckgram AI")
        self.placeholderLabel.font = self.inputView_.font
        self.placeholderLabel.textColor = theme.chat.inputPanel.inputPlaceholderColor
        self.sendButton.addTarget(self, action: #selector(self.sendPressed), for: .touchUpInside)

        for v in [self.pinnedStack, self.tableView, self.welcomeCard, self.quickScroll, self.inputPanel, self.quickStack, self.inputView_, self.placeholderLabel, self.sendButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        self.view.addSubview(self.tableView)
        self.view.addSubview(self.welcomeCard)
        self.view.addSubview(self.inputPanel)
        self.view.insertSubview(panelBottomFill, belowSubview: self.inputPanel)
        self.view.addSubview(self.pinnedStack)
        self.inputPanel.addSubview(self.quickScroll)
        self.inputPanel.addSubview(self.inputView_)
        self.inputPanel.addSubview(self.placeholderLabel)
        self.inputPanel.addSubview(self.sendButton)

        let inputHeight = self.inputView_.heightAnchor.constraint(equalToConstant: 36.0)
        self.inputHeight = inputHeight
        let safe = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            self.pinnedStack.topAnchor.constraint(equalTo: safe.topAnchor),
            self.pinnedStack.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.pinnedStack.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),

            self.tableView.topAnchor.constraint(equalTo: self.pinnedStack.isHidden ? safe.topAnchor : self.pinnedStack.bottomAnchor),
            self.tableView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.tableView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.tableView.bottomAnchor.constraint(equalTo: self.inputPanel.topAnchor),

            self.welcomeCard.centerXAnchor.constraint(equalTo: self.tableView.centerXAnchor),
            self.welcomeCard.centerYAnchor.constraint(equalTo: self.tableView.centerYAnchor),
            self.welcomeCard.widthAnchor.constraint(lessThanOrEqualTo: self.view.widthAnchor, constant: -48.0),
            self.welcomeCard.widthAnchor.constraint(lessThanOrEqualToConstant: 340.0),
            self.welcomeCard.topAnchor.constraint(greaterThanOrEqualTo: self.tableView.topAnchor, constant: 8.0),

            panelSeparator.topAnchor.constraint(equalTo: self.inputPanel.topAnchor),
            panelSeparator.leadingAnchor.constraint(equalTo: self.inputPanel.leadingAnchor),
            panelSeparator.trailingAnchor.constraint(equalTo: self.inputPanel.trailingAnchor),
            panelSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            self.quickScroll.topAnchor.constraint(equalTo: self.inputPanel.topAnchor, constant: hasQuick ? 6.0 : 0.0),
            self.quickScroll.leadingAnchor.constraint(equalTo: self.inputPanel.leadingAnchor),
            self.quickScroll.trailingAnchor.constraint(equalTo: self.inputPanel.trailingAnchor),
            self.quickScroll.heightAnchor.constraint(equalToConstant: hasQuick ? 34.0 : 0.0),
            self.quickStack.leadingAnchor.constraint(equalTo: self.quickScroll.contentLayoutGuide.leadingAnchor, constant: 10.0),
            self.quickStack.trailingAnchor.constraint(equalTo: self.quickScroll.contentLayoutGuide.trailingAnchor, constant: -10.0),
            self.quickStack.centerYAnchor.constraint(equalTo: self.quickScroll.frameLayoutGuide.centerYAnchor),
            self.quickStack.heightAnchor.constraint(equalToConstant: 30.0),

            panelBottomFill.topAnchor.constraint(equalTo: self.inputPanel.bottomAnchor),
            panelBottomFill.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            panelBottomFill.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            panelBottomFill.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),

            self.inputPanel.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.inputPanel.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.inputPanel.bottomAnchor.constraint(equalTo: self.view.keyboardLayoutGuide.topAnchor),
            self.inputView_.topAnchor.constraint(equalTo: self.quickScroll.bottomAnchor, constant: 7.0),
            self.inputView_.bottomAnchor.constraint(equalTo: self.inputPanel.bottomAnchor, constant: -7.0),
            self.inputView_.leadingAnchor.constraint(equalTo: self.inputPanel.leadingAnchor, constant: 10.0),
            self.inputView_.trailingAnchor.constraint(equalTo: self.sendButton.leadingAnchor, constant: -6.0),
            inputHeight,
            self.placeholderLabel.leadingAnchor.constraint(equalTo: self.inputView_.leadingAnchor, constant: 13.0),
            self.placeholderLabel.centerYAnchor.constraint(equalTo: self.inputView_.centerYAnchor),
            self.sendButton.trailingAnchor.constraint(equalTo: self.inputPanel.trailingAnchor, constant: -8.0),
            self.sendButton.bottomAnchor.constraint(equalTo: self.inputView_.bottomAnchor),
            self.sendButton.widthAnchor.constraint(equalToConstant: 36.0),
            self.sendButton.heightAnchor.constraint(equalToConstant: 36.0)
        ])

        if let prefill = self.prefill, !prefill.isEmpty {
            self.prefill = nil
            self.inputText = prefill
        }
        self.updateSendButton()
        self.updateEmpty()

        self.storeDisposable = (self.store.changes |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
            guard let self else {
                return
            }
            // e.g. the account's data was removed
            if self.store.get(self.conversation.id) == nil && !self.conversation.messages.isEmpty && self.streaming == nil {
                self.dismiss(animated: true)
            }
        })
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.scrollToBottom(animated: false)
        if !self.inputView_.text.isEmpty {
            self.inputView_.becomeFirstResponder()
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if self.isMovingFromParent || self.isBeingDismissed || self.navigationController?.isBeingDismissed == true {
            self.stopStreaming()
        }
    }

    private func makeTitleView() -> UIView {
        let avatar = UILabel()
        avatar.text = "AI"
        avatar.textAlignment = .center
        avatar.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
        avatar.textColor = .white
        avatar.backgroundColor = UIColor(red: 0.62, green: 0.40, blue: 0.95, alpha: 1.0)
        avatar.layer.cornerRadius = 17.0
        avatar.clipsToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 34.0), avatar.heightAnchor.constraint(equalToConstant: 34.0)])

        // A conversation opened by a feature with its own key (e.g. an agent, spec 22) shows its title.
        let keyedTitle = self.conversation.key != nil ? self.conversation.title : nil
        let title = UILabel()
        title.text = keyedTitle ?? "Luckgram AI"
        title.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
        title.textColor = self.theme.rootController.navigationBar.primaryTextColor
        let subtitle = UILabel()
        subtitle.text = keyedTitle != nil ? "Luckgram AI" : LuckgramStrings.pick("助手", "Assistant")
        subtitle.font = UIFont.systemFont(ofSize: 13.0)
        subtitle.textColor = self.theme.rootController.navigationBar.secondaryTextColor
        let texts = UIStackView(arrangedSubviews: [title, subtitle])
        texts.axis = .vertical
        texts.spacing = 0.0
        let stack = UIStackView(arrangedSubviews: [avatar, texts])
        stack.axis = .horizontal
        stack.spacing = 8.0
        stack.alignment = .center
        return stack
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let backgroundNode = self.backgroundNode {
            backgroundNode.frame = self.view.bounds
            backgroundNode.updateLayout(size: self.view.bounds.size, displayMode: .aspectFill, transition: .immediate)
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.applyNavigationBarAppearance()
    }

    /// specs#101: an opaque Telegram navigation bar in the app theme (no Liquid Glass capsules).
    private func applyNavigationBarAppearance() {
        let bar = self.theme.rootController.navigationBar
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = bar.opaqueBackgroundColor
        appearance.shadowColor = bar.separatorColor
        appearance.titleTextAttributes = [.foregroundColor: bar.primaryTextColor]
        self.navigationItem.standardAppearance = appearance
        self.navigationItem.scrollEdgeAppearance = appearance
        self.navigationItem.compactAppearance = appearance
        self.navigationController?.navigationBar.tintColor = bar.accentTextColor
    }

    /// specs#101: like Telegram's pinned message bar — accent line, icon, title, hint ›; the whole bar is tappable.
    private func makePinnedBar(_ entry: LuckgramAIRegistry.HeaderEntry) -> UIView {
        let bar = self.theme.rootController.navigationBar
        let accent = bar.accentTextColor
        let control = UIControl()
        control.backgroundColor = bar.opaqueBackgroundColor
        control.accessibilityLabel = LuckgramStrings.pick(entry.title.0, entry.title.1)
        control.accessibilityTraits = .button
        control.addAction(UIAction { [weak self] _ in
            guard let self else {
                return
            }
            entry.action(self)
        }, for: .touchUpInside)

        let line = UIView()
        line.backgroundColor = accent
        line.layer.cornerRadius = 1.0
        let icon = UIImageView(image: UIImage(systemName: entry.icon ?? "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .medium)))
        icon.tintColor = accent
        icon.contentMode = .center
        let title = UILabel()
        title.text = LuckgramStrings.pick(entry.title.0, entry.title.1)
        title.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        title.textColor = bar.primaryTextColor
        let hint = UILabel()
        hint.text = (entry.subtitle?().map { LuckgramStrings.pick($0.0, $0.1) + " " } ?? "") + "›"
        hint.font = UIFont.systemFont(ofSize: 15.0)
        hint.textColor = accent
        hint.setContentHuggingPriority(.required, for: .horizontal)
        let separator = UIView()
        separator.backgroundColor = bar.separatorColor
        for v in [line, icon, title, hint, separator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            control.addSubview(v)
        }
        NSLayoutConstraint.activate([
            control.heightAnchor.constraint(equalToConstant: 48.0),
            line.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 10.0),
            line.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 2.0),
            line.heightAnchor.constraint(equalToConstant: 32.0),
            icon.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 10.0),
            icon.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24.0),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8.0),
            title.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8.0),
            hint.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -14.0),
            hint.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: control.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])
        return control
    }

    /// specs#101: example questions on the welcome card (same on Android); a tap fills the input field.
    static let welcomeExamples: [(String, String)] = [
        ("把这段话改得更正式一点", "Make this paragraph more formal"),
        ("用三句话解释什么是区块链", "Explain blockchain in three sentences"),
        ("周末两天怎么安排一次短途旅行？", "Plan a two-day weekend trip for me"),
        ("帮我写一条给同事的生日祝福", "Write a birthday message for a coworker")
    ]

    private func buildWelcomeCard(service: PresentationThemeServiceMessageColorComponents) {
        let theme = self.theme
        let incoming = theme.chat.message.incoming
        let accent = theme.rootController.navigationBar.accentTextColor
        self.welcomeCard.backgroundColor = incoming.bubble.withWallpaper.fill.first ?? theme.list.plainBackgroundColor
        self.welcomeCard.layer.cornerRadius = 18.0
        self.welcomeCard.layer.shadowColor = UIColor.black.cgColor
        self.welcomeCard.layer.shadowOpacity = theme.overallDarkAppearance ? 0.0 : 0.08
        self.welcomeCard.layer.shadowRadius = 8.0
        self.welcomeCard.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)

        let badge = UIImageView(image: UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22.0, weight: .semibold)))
        badge.tintColor = .white
        badge.contentMode = .center
        badge.backgroundColor = accent
        badge.layer.cornerRadius = 24.0
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 48.0), badge.heightAnchor.constraint(equalToConstant: 48.0)])

        let title = UILabel()
        title.text = LuckgramStrings.pick("有什么可以帮你？", "How can I help?")
        title.font = UIFont.systemFont(ofSize: 18.0, weight: .semibold)
        title.textColor = incoming.primaryTextColor
        title.textAlignment = .center
        let subtitle = UILabel()
        subtitle.text = LuckgramStrings.pick("可以提问、总结或改写长文、讲解、解题。", "Ask anything, summarize or rewrite text, explain, solve problems.")
        subtitle.font = UIFont.systemFont(ofSize: 14.0)
        subtitle.textColor = incoming.secondaryTextColor
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let examples = UIStackView()
        examples.axis = .vertical
        examples.spacing = 8.0
        for example in LuckgramAIChatController.welcomeExamples {
            let text = LuckgramStrings.pick(example.0, example.1)
            var config = UIButton.Configuration.plain()
            config.title = text
            config.baseForegroundColor = accent
            config.titleAlignment = .leading
            config.contentInsets = NSDirectionalEdgeInsets(top: 9.0, leading: 12.0, bottom: 9.0, trailing: 12.0)
            config.background.backgroundColor = accent.withAlphaComponent(0.1)
            config.background.cornerRadius = 12.0
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.systemFont(ofSize: 15.0)
                return attributes
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                guard let self else {
                    return
                }
                self.inputText = text
                self.inputView_.becomeFirstResponder()
            })
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 0
            examples.addArrangedSubview(button)
        }

        let stack = UIStackView(arrangedSubviews: [badge, title, subtitle, examples])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8.0
        stack.setCustomSpacing(12.0, after: badge)
        stack.setCustomSpacing(16.0, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        examples.translatesAutoresizingMaskIntoConstraints = false
        // The card is as tall as its content while there is room. With the keyboard up or in landscape there
        // is not: the card then stops at the available height and its content scrolls, instead of the
        // example buttons being squeezed on top of each other.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delaysContentTouches = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.layer.cornerRadius = 18.0
        self.welcomeCard.addSubview(scroll)
        scroll.addSubview(stack)
        let fitsContent = self.welcomeCard.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor)
        fitsContent.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: self.welcomeCard.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: self.welcomeCard.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: self.welcomeCard.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: self.welcomeCard.trailingAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20.0),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16.0),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16.0),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16.0),
            examples.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fitsContent
        ])
    }

    /// specs#101: quick buttons — accent text on a light accent tint with an accent outline, never truncated.
    private func makeChip(title: String, icon: String?, action: @escaping () -> Void) -> UIView {
        let accent = self.theme.chat.inputPanel.panelControlAccentColor
        var config = UIButton.Configuration.plain()
        config.title = title
        if let icon {
            config.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .medium))
            config.imagePadding = 4.0
        }
        config.baseForegroundColor = accent
        config.background.backgroundColor = accent.withAlphaComponent(0.1)
        config.background.strokeColor = accent.withAlphaComponent(0.5)
        config.background.strokeWidth = 1.0
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 12.0, bottom: 4.0, trailing: 12.0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func updateSendButton() {
        let isStop = self.streaming != nil
        let image = UIImage(systemName: isStop ? "stop.circle.fill" : "arrow.up.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30.0, weight: .regular))
        self.sendButton.setImage(image, for: .normal)
        let enabled = isStop || !self.inputView_.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.sendButton.tintColor = enabled ? self.theme.chat.inputPanel.actionControlFillColor : self.theme.chat.inputPanel.inputPlaceholderColor
        self.sendButton.accessibilityLabel = isStop ? LuckgramStrings.pick("停止", "Stop") : LuckgramStrings.pick("发送", "Send")
        self.placeholderLabel.isHidden = !self.inputView_.text.isEmpty
    }

    private func updateInputHeight() {
        let width = max(1.0, self.inputView_.bounds.width)
        let fitting = self.inputView_.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = self.inputView_.font?.lineHeight ?? 20.0
        let maxHeight = lineHeight * 6.0 + 16.0
        self.inputHeight?.constant = min(max(36.0, fitting), maxHeight)
        self.inputView_.isScrollEnabled = fitting > maxHeight
    }

    public func textViewDidChange(_ textView: UITextView) {
        self.updateSendButton()
        self.updateInputHeight()
    }

    private func updateEmpty() {
        self.welcomeCard.isHidden = !self.conversation.messages.isEmpty
    }

    private func scrollToBottom(animated: Bool) {
        let count = self.conversation.messages.count
        if count > 0 {
            self.tableView.scrollToRow(at: IndexPath(row: count - 1, section: 0), at: .bottom, animated: animated)
        }
    }

    private var isAtBottom: Bool {
        let offset = self.tableView.contentOffset.y + self.tableView.bounds.height - self.tableView.adjustedContentInset.bottom
        return offset >= self.tableView.contentSize.height - 40.0
    }

    @objc private func closePressed() {
        self.stopStreaming()
        self.view.endEditing(true)
        self.dismiss(animated: true)
    }

    @objc private func newPressed() {
        self.switchTo(self.store.create())
    }

    @objc private func historyPressed() {
        let controller = LuckgramAIHistoryController(context: self.context, theme: self.theme, onPick: { [weak self] conversation in
            self?.switchTo(conversation)
        })
        self.navigationController?.pushViewController(controller, animated: true)
    }

    private func switchTo(_ conversation: LuckgramAIConversation) {
        if conversation === self.conversation {
            return
        }
        self.stopStreaming()
        self.conversation = conversation
        self.navigationItem.titleView = self.makeTitleView()
        self.tableView.reloadData()
        self.updateEmpty()
        self.scrollToBottom(animated: false)
    }

    // MARK: - Sending

    @objc private func sendPressed() {
        if self.streaming != nil {
            self.stopStreaming()
            return
        }
        let text = self.inputView_.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return
        }
        self.inputText = ""
        if LuckgramAIRegistry.intercept(host: self, text: text) {
            return
        }
        self.addMessage(LuckgramAIConversation.Message(role: LuckgramAIConversation.Message.roleUser, text: text))
        self.requestReply()
    }

    private func requestReply() {
        let conversation = self.conversation
        let reply = LuckgramAIConversation.Message(role: LuckgramAIConversation.Message.roleAssistant, text: "")
        reply.isPending = true
        let maxChars = LuckgramSettings.shared.remoteInt("ai.max_input_chars", default: 60000)
        let messages = conversation.requestMessages(maxChars: maxChars)
        conversation.messages.append(reply)
        self.insertedLast()
        self.streaming = reply
        self.updateSendButton()

        let context = self.context
        let tier = conversation.modelTier
        var params = conversation.requestParams // spec 29: the premium model goes as model_tier
        if let tier {
            params = (params ?? [:]).merging(["model_tier": tier], uniquingKeysWith: { current, _ in current })
        }
        self.requestDisposable?.dispose()
        self.requestDisposable = (LuckgramAI.shared.chat(context: context, present: { [weak self] c in
            self?.presentAlert(c)
        }, task: conversation.task, params: params, messages: messages, stream: true)
        |> deliverOnMainQueue).startStrict(next: { [weak self] event in
            guard let self, self.streaming === reply else {
                return
            }
            let atBottom = self.isAtBottom
            switch event {
            case let .delta(_, text):
                reply.text = text
                self.reload(reply)
            case let .completed(text):
                reply.text = text
                self.finishReply(conversation, reply, error: nil)
                if tier != nil {
                    LuckgramProModelChoice.onPremiumReply()
                }
            }
            if atBottom {
                self.scrollToBottom(animated: false)
            }
        }, error: { [weak self] error in
            guard let self, self.streaming === reply else {
                return
            }
            self.finishReply(conversation, reply, error: error)
            LuckgramProModelChoice.onError(host: self, code: error.code) // spec 29
        }, completed: { [weak self] in
            guard let self, self.streaming === reply else {
                return
            }
            self.finishReply(conversation, reply, error: nil)
        })
    }

    private func presentAlert(_ controller: ViewController) {
        // The consent alert is a Telegram ViewController; show it in the window above this sheet.
        self.context.sharedContext.mainWindow?.present(controller, on: .root)
    }

    private func finishReply(_ conversation: LuckgramAIConversation, _ reply: LuckgramAIConversation.Message, error: LuckgramAIError?) {
        self.streaming = nil
        self.requestDisposable?.dispose()
        self.requestDisposable = nil
        reply.isPending = false
        if let error, error.code != LuckgramAIError.cancelled {
            reply.errorCode = error.code
        } else if (reply.text ?? "").isEmpty {
            conversation.messages.removeAll(where: { $0 === reply })
            if conversation === self.conversation {
                self.tableView.reloadData()
            }
        }
        if conversation === self.conversation {
            self.reload(reply)
            self.updateSendButton()
            self.updateEmpty()
        }
        self.store.save(conversation)
    }

    /// Stops the reply being streamed, keeping what has arrived.
    private func stopStreaming() {
        guard let reply = self.streaming else {
            return
        }
        self.requestDisposable?.dispose()
        self.requestDisposable = nil
        self.finishReply(self.conversation, reply, error: nil)
    }

    private func retry(_ failed: LuckgramAIConversation.Message) {
        if self.streaming != nil {
            return
        }
        self.conversation.messages.removeAll(where: { $0 === failed })
        self.tableView.reloadData()
        self.requestReply()
    }

    // MARK: - LuckgramAIChatHost

    public var inputText: String {
        get {
            return self.inputView_.text ?? ""
        }
        set {
            self.inputView_.text = newValue
            self.updateSendButton()
            self.updateInputHeight()
            if self.isViewLoaded && self.view.window != nil {
                self.inputView_.becomeFirstResponder()
            }
        }
    }

    public func addMessage(_ message: LuckgramAIConversation.Message) {
        if self.conversation.title == nil, message.isUser, let text = message.text {
            let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            self.conversation.title = t.count > 40 ? String(t.prefix(40)) + "…" : t
        }
        self.conversation.messages.append(message)
        self.insertedLast()
        self.store.save(self.conversation)
    }

    public func updateMessage(_ message: LuckgramAIConversation.Message) {
        self.reload(message)
        self.store.save(self.conversation)
    }

    private func insertedLast() {
        if self.isViewLoaded {
            self.tableView.insertRows(at: [IndexPath(row: self.conversation.messages.count - 1, section: 0)], with: .none)
            self.scrollToBottom(animated: true)
        }
        self.updateEmpty()
    }

    private func reload(_ message: LuckgramAIConversation.Message) {
        guard self.isViewLoaded, let index = self.conversation.messages.firstIndex(where: { $0 === message }) else {
            return
        }
        UIView.performWithoutAnimation {
            self.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        }
    }

    // MARK: - Table

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.conversation.messages.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "bubble", for: indexPath) as! BubbleCell
        let message = self.conversation.messages[indexPath.row]
        cell.configure(message: message, theme: self.theme, width: tableView.bounds.width)
        cell.menuProvider = { [weak self] in
            return self?.menu(for: message)
        }
        return cell
    }

    private func menu(for message: LuckgramAIConversation.Message) -> UIMenu? {
        if message.isPending {
            return nil
        }
        var actions: [UIMenuElement] = []
        let copyText: String?
        if message.type == LuckgramAIConversation.Message.typeText {
            copyText = message.text
        } else {
            copyText = LuckgramAIRegistry.renderer(for: message.type)?.copyText(message)
        }
        if let copyText, !copyText.isEmpty {
            actions.append(UIAction(title: LuckgramStrings.pick("复制", "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = copyText
            })
        }
        if message.errorCode != nil && !message.isUser {
            actions.append(UIAction(title: LuckgramStrings.pick("重试", "Retry"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.retry(message)
            })
        }
        actions.append(UIAction(title: LuckgramStrings.pick("删除", "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self else {
                return
            }
            self.conversation.messages.removeAll(where: { $0 === message })
            self.tableView.reloadData()
            self.updateEmpty()
            self.store.save(self.conversation)
        })
        return UIMenu(children: actions)
    }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: UIEdgeInsets(top: 10.0, left: 16.0, bottom: 10.0, right: 16.0)))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 32.0, height: size.height + 20.0)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: UIEdgeInsets(top: 10.0, left: 16.0, bottom: 10.0, right: 16.0)), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -10.0, left: -16.0, bottom: -10.0, right: -16.0))
    }
}

private final class BubbleCell: UITableViewCell, UIContextMenuInteractionDelegate {
    private let bubble = UIView()
    private let textView = UITextView()
    private let errorLabel = UILabel()
    private var customView: UIView?
    private var customType: String?
    private var leading: NSLayoutConstraint?
    private var trailing: NSLayoutConstraint?
    private var customHeight: NSLayoutConstraint?
    private var customWidth: NSLayoutConstraint?
    private let stack = UIStackView()
    var menuProvider: (() -> UIMenu?)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.selectionStyle = .none

        self.bubble.layer.cornerRadius = 16.0
        self.bubble.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(self.bubble)

        self.textView.isEditable = false
        self.textView.isScrollEnabled = false
        self.textView.backgroundColor = .clear
        self.textView.textContainerInset = .zero
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.dataDetectorTypes = []

        self.errorLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.errorLabel.numberOfLines = 0
        self.errorLabel.textColor = .systemRed

        self.stack.axis = .vertical
        self.stack.spacing = 2.0
        self.stack.alignment = .leading
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.stack.addArrangedSubview(self.textView)
        self.stack.addArrangedSubview(self.errorLabel)
        self.bubble.addSubview(self.stack)

        let leading = self.bubble.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 8.0)
        let trailing = self.bubble.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -8.0)
        self.leading = leading
        self.trailing = trailing
        NSLayoutConstraint.activate([
            self.bubble.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 3.0),
            self.bubble.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -3.0),
            self.bubble.widthAnchor.constraint(lessThanOrEqualTo: self.contentView.widthAnchor, constant: -56.0),
            self.bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 560.0),
            self.stack.topAnchor.constraint(equalTo: self.bubble.topAnchor, constant: 7.0),
            self.stack.bottomAnchor.constraint(equalTo: self.bubble.bottomAnchor, constant: -8.0),
            self.stack.leadingAnchor.constraint(equalTo: self.bubble.leadingAnchor, constant: 11.0),
            self.stack.trailingAnchor.constraint(equalTo: self.bubble.trailingAnchor, constant: -11.0)
        ])
        self.bubble.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: LuckgramAIConversation.Message, theme: PresentationTheme, width: CGFloat) {
        let isOut = message.isUser
        let colors = isOut ? theme.chat.message.outgoing : theme.chat.message.incoming
        self.bubble.backgroundColor = colors.bubble.withWallpaper.fill.first ?? (isOut ? .systemBlue : .secondarySystemBackground)
        self.leading?.isActive = !isOut
        self.trailing?.isActive = isOut

        let font = UIFont.systemFont(ofSize: 17.0)
        let maxWidth = min(width - 56.0, 560.0) - 22.0
        let isText = message.type == LuckgramAIConversation.Message.typeText
        let renderer = isText ? nil : LuckgramAIRegistry.renderer(for: message.type)

        if let renderer {
            if self.customType != message.type {
                self.customView?.removeFromSuperview()
                let view = renderer.makeView()
                view.translatesAutoresizingMaskIntoConstraints = false
                self.stack.insertArrangedSubview(view, at: 0)
                let w = view.widthAnchor.constraint(equalToConstant: 10.0)
                let h = view.heightAnchor.constraint(equalToConstant: 10.0)
                NSLayoutConstraint.activate([w, h])
                self.customWidth = w
                self.customHeight = h
                self.customView = view
                self.customType = message.type
            }
            if let view = self.customView {
                let size = renderer.size(message: message, maxWidth: maxWidth)
                self.customWidth?.constant = size.width
                self.customHeight?.constant = size.height
                renderer.update(view: view, message: message, isOutgoing: isOut, maxWidth: maxWidth)
                view.isHidden = false
            }
            self.textView.isHidden = true
        } else {
            self.customView?.isHidden = true
            self.textView.isHidden = false
            if !isText {
                self.textView.attributedText = NSAttributedString(string: LuckgramStrings.pick("此消息类型暂不支持显示", "This message can't be shown"), attributes: [.font: font, .foregroundColor: colors.secondaryTextColor])
            } else if isOut {
                self.textView.attributedText = NSAttributedString(string: message.text ?? "", attributes: [.font: font, .foregroundColor: colors.primaryTextColor])
            } else if message.isPending && (message.text ?? "").isEmpty {
                self.textView.attributedText = NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: colors.primaryTextColor])
            } else {
                self.textView.attributedText = LuckgramAIMarkdown.attributedString(message.text ?? "", font: font, textColor: colors.primaryTextColor, linkColor: colors.linkTextColor)
            }
            self.textView.linkTextAttributes = [.foregroundColor: colors.linkTextColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
        if let code = message.errorCode {
            self.errorLabel.text = LuckgramStrings.errorMessage(code)
            self.errorLabel.isHidden = false
            if isText && (message.text ?? "").isEmpty {
                self.textView.isHidden = true
            }
        } else {
            self.errorLabel.isHidden = true
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = self.menuProvider?() else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { _ in menu })
    }
}
