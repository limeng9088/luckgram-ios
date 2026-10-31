import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramPresentationData
import AccountContext

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

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = PaddedLabel()
    private let headerScroll = UIScrollView()
    private let headerStack = UIStackView()
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
        self.theme = context.sharedContext.currentPresentationData.with { $0 }.theme
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
        self.view.backgroundColor = theme.list.blocksBackgroundColor
        self.navigationItem.titleView = self.makeTitleView()
        if self.navigationController?.viewControllers.first === self {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(self.closePressed))
        }
        let newItem = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .plain, target: self, action: #selector(self.newPressed))
        newItem.accessibilityLabel = LuckgramStrings.pick("新对话", "New chat")
        let historyItem = UIBarButtonItem(image: UIImage(systemName: "clock.arrow.circlepath"), style: .plain, target: self, action: #selector(self.historyPressed))
        historyItem.accessibilityLabel = LuckgramStrings.pick("历史对话", "Chat history")
        self.navigationItem.rightBarButtonItems = [historyItem, newItem]

        // extension point 3: entries at the top of the page
        self.headerStack.axis = .horizontal
        self.headerStack.spacing = 6.0
        self.headerScroll.showsHorizontalScrollIndicator = false
        self.headerScroll.backgroundColor = theme.list.plainBackgroundColor
        self.headerScroll.addSubview(self.headerStack)
        for entry in LuckgramAIRegistry.headerEntries {
            self.headerStack.addArrangedSubview(self.makeChip(title: LuckgramStrings.pick(entry.title.0, entry.title.1), icon: entry.icon, action: { [weak self] in
                guard let self else {
                    return
                }
                entry.action(self)
            }))
        }
        self.headerScroll.isHidden = self.headerStack.arrangedSubviews.isEmpty

        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.separatorStyle = .none
        self.tableView.backgroundColor = .clear
        self.tableView.keyboardDismissMode = .interactive
        self.tableView.allowsSelection = false
        self.tableView.contentInset = UIEdgeInsets(top: 6.0, left: 0.0, bottom: 6.0, right: 0.0)
        self.tableView.register(BubbleCell.self, forCellReuseIdentifier: "bubble")

        self.emptyLabel.text = LuckgramStrings.pick("有什么可以帮你？\n可以提问、总结或改写长文、讲解、解题。", "How can I help?\nAsk anything, summarize or rewrite text, explain, solve problems.")
        self.emptyLabel.numberOfLines = 0
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.font = UIFont.systemFont(ofSize: 15.0)
        self.emptyLabel.textColor = theme.chat.serviceMessage.components.withDefaultWallpaper.primaryText
        self.emptyLabel.backgroundColor = theme.chat.serviceMessage.components.withDefaultWallpaper.fill
        self.emptyLabel.layer.cornerRadius = 14.0
        self.emptyLabel.clipsToBounds = true

        // spec 18 需求 3 + extension point 1: quick buttons above the input field
        self.quickStack.axis = .horizontal
        self.quickStack.spacing = 6.0
        self.quickScroll.showsHorizontalScrollIndicator = false
        self.quickScroll.addSubview(self.quickStack)
        for action in LuckgramAIRegistry.quickActions {
            self.quickStack.addArrangedSubview(self.makeChip(title: LuckgramStrings.pick(action.title.0, action.title.1), icon: action.icon, action: { [weak self] in
                guard let self else {
                    return
                }
                action.action(self)
            }))
        }

        self.inputPanel.backgroundColor = theme.chat.inputPanel.panelBackgroundColor
        self.inputView_.font = UIFont.systemFont(ofSize: 17.0)
        self.inputView_.textColor = theme.chat.inputPanel.inputTextColor
        self.inputView_.backgroundColor = theme.chat.inputPanel.inputBackgroundColor
        self.inputView_.layer.cornerRadius = 18.0
        self.inputView_.textContainerInset = UIEdgeInsets(top: 8.0, left: 8.0, bottom: 8.0, right: 8.0)
        self.inputView_.delegate = self
        self.inputView_.keyboardAppearance = theme.overallDarkAppearance ? .dark : .light
        self.placeholderLabel.text = LuckgramStrings.pick("给 Luckgram AI 发消息", "Message Luckgram AI")
        self.placeholderLabel.font = self.inputView_.font
        self.placeholderLabel.textColor = theme.chat.inputPanel.inputPlaceholderColor
        self.sendButton.addTarget(self, action: #selector(self.sendPressed), for: .touchUpInside)

        for v in [self.headerScroll, self.tableView, self.emptyLabel, self.quickScroll, self.inputPanel, self.headerStack, self.quickStack, self.inputView_, self.placeholderLabel, self.sendButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        self.view.addSubview(self.headerScroll)
        self.view.addSubview(self.tableView)
        self.view.addSubview(self.emptyLabel)
        self.view.addSubview(self.quickScroll)
        self.view.addSubview(self.inputPanel)
        self.inputPanel.addSubview(self.inputView_)
        self.inputPanel.addSubview(self.placeholderLabel)
        self.inputPanel.addSubview(self.sendButton)

        let inputHeight = self.inputView_.heightAnchor.constraint(equalToConstant: 36.0)
        self.inputHeight = inputHeight
        let safe = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            self.headerScroll.topAnchor.constraint(equalTo: safe.topAnchor),
            self.headerScroll.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.headerScroll.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.headerScroll.heightAnchor.constraint(equalToConstant: self.headerScroll.isHidden ? 0.0 : 44.0),
            self.headerStack.leadingAnchor.constraint(equalTo: self.headerScroll.contentLayoutGuide.leadingAnchor, constant: 8.0),
            self.headerStack.trailingAnchor.constraint(equalTo: self.headerScroll.contentLayoutGuide.trailingAnchor, constant: -8.0),
            self.headerStack.centerYAnchor.constraint(equalTo: self.headerScroll.frameLayoutGuide.centerYAnchor),
            self.headerStack.heightAnchor.constraint(equalToConstant: 30.0),

            self.tableView.topAnchor.constraint(equalTo: self.headerScroll.bottomAnchor),
            self.tableView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.tableView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.tableView.bottomAnchor.constraint(equalTo: self.quickScroll.topAnchor),

            self.emptyLabel.centerXAnchor.constraint(equalTo: self.tableView.centerXAnchor),
            self.emptyLabel.centerYAnchor.constraint(equalTo: self.tableView.centerYAnchor),
            self.emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: self.view.widthAnchor, constant: -64.0),

            self.quickScroll.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.quickScroll.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.quickScroll.heightAnchor.constraint(equalToConstant: 40.0),
            self.quickScroll.bottomAnchor.constraint(equalTo: self.inputPanel.topAnchor),
            self.quickStack.leadingAnchor.constraint(equalTo: self.quickScroll.contentLayoutGuide.leadingAnchor, constant: 8.0),
            self.quickStack.trailingAnchor.constraint(equalTo: self.quickScroll.contentLayoutGuide.trailingAnchor, constant: -8.0),
            self.quickStack.centerYAnchor.constraint(equalTo: self.quickScroll.frameLayoutGuide.centerYAnchor),
            self.quickStack.heightAnchor.constraint(equalToConstant: 30.0),

            self.inputPanel.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.inputPanel.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.inputPanel.bottomAnchor.constraint(equalTo: self.view.keyboardLayoutGuide.topAnchor),
            self.inputView_.topAnchor.constraint(equalTo: self.inputPanel.topAnchor, constant: 7.0),
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

        let title = UILabel()
        title.text = "Luckgram AI"
        title.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
        title.textColor = self.theme.rootController.navigationBar.primaryTextColor
        let subtitle = UILabel()
        subtitle.text = LuckgramStrings.pick("助手", "Assistant")
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

    private func makeChip(title: String, icon: String?, action: @escaping () -> Void) -> UIView {
        var config = UIButton.Configuration.filled()
        config.title = title
        if let icon {
            config.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .medium))
            config.imagePadding = 4.0
        }
        config.cornerStyle = .capsule
        config.baseBackgroundColor = self.theme.chat.serviceMessage.components.withDefaultWallpaper.fill
        config.baseForegroundColor = self.theme.chat.serviceMessage.components.withDefaultWallpaper.primaryText
        config.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 12.0, bottom: 4.0, trailing: 12.0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
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
        self.emptyLabel.isHidden = !self.conversation.messages.isEmpty
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
        self.requestDisposable?.dispose()
        self.requestDisposable = (LuckgramAI.shared.chat(context: context, present: { [weak self] c in
            self?.presentAlert(c)
        }, task: conversation.task, messages: messages, stream: true)
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
            }
            if atBottom {
                self.scrollToBottom(animated: false)
            }
        }, error: { [weak self] error in
            guard let self, self.streaming === reply else {
                return
            }
            self.finishReply(conversation, reply, error: error)
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
        self.bubble.backgroundColor = colors.bubble.withoutWallpaper.fill.first ?? (isOut ? .systemBlue : .secondarySystemBackground)
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
