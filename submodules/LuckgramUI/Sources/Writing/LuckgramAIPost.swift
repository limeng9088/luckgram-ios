import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext

/// spec 24: "写帖子" in the ✦ menu (registered through 21's extension point), only in channels
/// where the user can post. A topic and the channel's last 20 text posts (as style examples, sent
/// only with this request) give a streamed draft in the panel above the field; the draft can be
/// edited, shortened, given more emoji, translated or rewritten, then posted (now or scheduled)
/// through the chat's own send path. Same requests as Android's `AiPostText`.
public enum LuckgramAIPost {
    static let examplesCount = 20
    static let maxExampleChars = 1500

    static let shorter = "Make it shorter, keeping the key information."
    static let emoji = "Add more fitting emoji, keeping the text."
    static let rewrite = "Rewrite it with the same information in a fresh way."

    static func translate(_ language: String) -> String {
        return "Translate it into \(language). Keep the formatting and emoji."
    }

    static let languages: [(String, String)] = [
        ("English", "English"), ("Chinese (Simplified)", "简体中文"), ("Japanese", "日本語"), ("Korean", "한국어"),
        ("Russian", "Русский"), ("Spanish", "Español"), ("French", "Français"), ("German", "Deutsch")
    ]

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiPost)
    }

    /// The registration line used by `LuckgramAIWritingFeatures`.
    static var menuItem: LuckgramAIWriting.MenuItem {
        return .init(id: "ai_post", title: ("写帖子", "Write a post"), icon: "square.and.pencil", order: 10, allowsEmptyText: true, isVisible: { peer in
            return LuckgramAIPost.isEnabled && LuckgramAIWriting.canPostInChannel(peer)
        }, action: { host in
            PostPanel(host: host).show()
        })
    }

    static func examples(_ posts: [String], maxChars: Int) -> String {
        var out = ""
        var count = 0
        for post in posts {
            if count >= self.examplesCount {
                break
            }
            var t = post.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                continue
            }
            if t.count > self.maxExampleChars {
                t = String(t.prefix(self.maxExampleChars)) + "…"
            }
            if out.count + t.count + 8 > maxChars {
                break
            }
            out += "---\n" + t + "\n"
            count += 1
        }
        return out
    }

    static func generate(examples: String, topic: String) -> String {
        var s = ""
        if !examples.isEmpty {
            s += "Example posts from this channel (style reference only, do not copy):\n" + examples + "---\n\n"
        }
        return s + "Topic: " + topic.trimmingCharacters(in: .whitespacesAndNewlines) + "\nWrite a new post for the channel."
    }

    static func edit(examples: String, draft: String, instruction: String) -> String {
        var s = ""
        if !examples.isEmpty {
            s += "Example posts from this channel (style reference only, do not copy):\n" + examples + "---\n\n"
        }
        return s + "Current draft:\n" + draft.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nInstruction: " + instruction
    }

    /// The channel's recent text posts, newest first.
    static func recentPosts(context: AccountContext, peerId: EnginePeer.Id) -> Signal<[String], NoError> {
        return context.engine.messages.searchMessages(location: .peer(peerId: peerId, fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil), query: "", state: nil, limit: 50)
        |> take(1)
        |> map { result, _ -> [String] in
            return result.messages.sorted(by: { $0.id.id > $1.id.id }).map { $0.text }.filter { !$0.isEmpty }.prefix(self.examplesCount).map { $0 }
        }
    }

    private final class PostPanel: UIView, UITextFieldDelegate {
        private weak var host: LuckgramAIWritingHost?
        private let titleLabel = UILabel()
        private let closeButton = UIButton(type: .system)
        private let topicField = UITextField()
        private let generateButton = UIButton(type: .system)
        private let statusLabel = UILabel()
        private let draftView = UITextView()
        private var editButtons: [UIButton] = []
        private let scheduleButton = UIButton(type: .system)
        private let postButton = UIButton(type: .system)
        private var examples = ""
        private var hasDraft = false
        private var busy = false
        private var disposable: Disposable?

        init(host: LuckgramAIWritingHost) {
            self.host = host
            super.init(frame: .zero)
            self.titleLabel.text = LuckgramStrings.pick("写帖子", "Write a post")
            self.titleLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            self.titleLabel.textColor = .secondaryLabel
            self.closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            self.closeButton.accessibilityLabel = LuckgramStrings.pick("关闭", "Close")
            self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
            self.topicField.placeholder = LuckgramStrings.pick("主题，例如：周末促销，玫瑰八折", "Topic, e.g. Weekend sale, roses 20% off")
            self.topicField.font = UIFont.systemFont(ofSize: 15.0)
            self.topicField.backgroundColor = .tertiarySystemFill
            self.topicField.layer.cornerRadius = 10.0
            self.topicField.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 10.0, height: 1.0))
            self.topicField.leftViewMode = .always
            self.topicField.returnKeyType = .go
            self.topicField.delegate = self
            let current = host.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty {
                self.topicField.text = current
            }
            self.generateButton.setTitle(LuckgramStrings.pick("生成", "Write"), for: .normal)
            self.generateButton.addTarget(self, action: #selector(self.generatePressed), for: .touchUpInside)
            self.statusLabel.font = UIFont.systemFont(ofSize: 14.0)
            self.statusLabel.textColor = .secondaryLabel
            self.statusLabel.numberOfLines = 0
            self.draftView.font = UIFont.systemFont(ofSize: 15.0)
            self.draftView.backgroundColor = .tertiarySystemFill
            self.draftView.layer.cornerRadius = 10.0
            self.draftView.textContainerInset = UIEdgeInsets(top: 8.0, left: 6.0, bottom: 8.0, right: 6.0)
            let actions: [(String, String, Selector)] = [
                ("更简短", "Shorter", #selector(self.shorterPressed)),
                ("多点表情", "More emoji", #selector(self.emojiPressed)),
                ("翻译", "Translate", #selector(self.translatePressed)),
                ("重写", "Rewrite", #selector(self.rewritePressed))
            ]
            for (zh, en, selector) in actions {
                let button = UIButton(type: .system)
                button.setTitle(LuckgramStrings.pick(zh, en), for: .normal)
                button.addTarget(self, action: selector, for: .touchUpInside)
                self.editButtons.append(button)
            }
            self.scheduleButton.setTitle(LuckgramStrings.pick("定时发布", "Schedule"), for: .normal)
            self.scheduleButton.addTarget(self, action: #selector(self.schedulePressed), for: .touchUpInside)
            var postConfig = UIButton.Configuration.filled()
            postConfig.title = LuckgramStrings.pick("发布", "Post")
            postConfig.cornerStyle = .capsule
            self.postButton.configuration = postConfig
            self.postButton.addTarget(self, action: #selector(self.postPressed), for: .touchUpInside)
            for button in [self.generateButton, self.scheduleButton] + self.editButtons {
                button.titleLabel?.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            }
            for v in [self.titleLabel, self.closeButton, self.topicField, self.generateButton, self.statusLabel, self.draftView, self.scheduleButton, self.postButton] + self.editButtons as [UIView] {
                self.addSubview(v)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            self.disposable?.dispose()
        }

        func show() {
            self.relayout()
            self.topicField.becomeFirstResponder()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            self.generatePressed()
            return false
        }

        @objc private func closePressed() {
            self.disposable?.dispose()
            self.host?.hidePanel(self)
        }

        private var maxChars: Int {
            return LuckgramSettings.shared.remoteInt("ai.max_input_chars", default: 60000)
        }

        @objc private func generatePressed() {
            let topic = (self.topicField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty, let host = self.host, let peerId = host.peerId, !self.busy else {
                return
            }
            let maxChars = self.maxChars
            // spec 24 需求 5: the example posts go only into this request
            self.run(LuckgramAIPost.recentPosts(context: host.context, peerId: peerId)
            |> map { [weak self] posts -> String in
                let examples = LuckgramAIPost.examples(posts, maxChars: maxChars / 2)
                self?.examples = examples
                return LuckgramAIPost.generate(examples: examples, topic: topic)
            })
        }

        private func edit(_ instruction: String) {
            let draft = self.draftView.text ?? ""
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.busy {
                return
            }
            self.run(.single(LuckgramAIPost.edit(examples: self.examples, draft: draft, instruction: instruction)))
        }

        @objc private func shorterPressed() {
            self.edit(LuckgramAIPost.shorter)
        }

        @objc private func emojiPressed() {
            self.edit(LuckgramAIPost.emoji)
        }

        @objc private func rewritePressed() {
            self.edit(LuckgramAIPost.rewrite)
        }

        @objc private func translatePressed() {
            let sheet = UIAlertController(title: LuckgramStrings.pick("翻译成", "Translate into"), message: nil, preferredStyle: .actionSheet)
            for (english, native) in LuckgramAIPost.languages {
                sheet.addAction(UIAlertAction(title: native, style: .default) { [weak self] _ in
                    self?.edit(LuckgramAIPost.translate(english))
                })
            }
            sheet.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel))
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = self
                popover.sourceRect = self.bounds
            }
            self.host?.present(sheet)
        }

        private func run(_ content: Signal<String, NoError>) {
            guard let host = self.host else {
                return
            }
            self.busy = true
            self.statusLabel.text = LuckgramStrings.pick("正在写…", "Writing…")
            self.relayout()
            let context = host.context
            self.disposable?.dispose()
            self.disposable = (content
            |> castError(LuckgramAIError.self)
            |> mapToSignal { text -> Signal<LuckgramAI.ChatEvent, LuckgramAIError> in
                return LuckgramAI.shared.chat(context: context, present: { [weak host] c in
                    host?.present(c)
                }, task: .post, messages: [.user(text)], stream: true)
            }
            |> deliverOnMainQueue).startStrict(next: { [weak self] event in
                guard let self else {
                    return
                }
                switch event {
                case let .delta(_, text):
                    self.showDraft(text)
                case let .completed(text):
                    self.busy = false
                    self.statusLabel.text = nil
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.showDraft(trimmed)
                    } else {
                        self.relayout()
                    }
                }
            }, error: { [weak self] error in
                guard let self else {
                    return
                }
                self.busy = false
                self.statusLabel.text = error.code == LuckgramAIError.consentDenied ? nil : error.localizedMessage
                self.relayout()
            })
        }

        private func showDraft(_ text: String) {
            self.hasDraft = true
            self.draftView.text = text
            self.relayout()
        }

        /// spec 24 需求 4: posted through the chat's own send path, like the admin's Send button.
        private func publish(schedule: Bool) {
            let draft = (self.draftView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.isEmpty, !self.busy, let host = self.host else {
                return
            }
            self.draftView.resignFirstResponder()
            host.send(draft, schedule: schedule)
            host.hidePanel(self)
        }

        @objc private func schedulePressed() {
            self.publish(schedule: true)
        }

        @objc private func postPressed() {
            self.publish(schedule: false)
        }

        private func relayout() {
            guard let host = self.host else {
                return
            }
            let width = max(240.0, self.superview?.bounds.width ?? UIScreen.main.bounds.width - 16.0)
            let inset: CGFloat = 12.0
            self.titleLabel.frame = CGRect(x: inset, y: 0.0, width: width - 60.0, height: 36.0)
            self.closeButton.frame = CGRect(x: width - 40.0, y: 0.0, width: 40.0, height: 36.0)
            var y: CGFloat = 36.0
            self.generateButton.sizeToFit()
            let generateWidth = self.generateButton.bounds.width + 16.0
            self.topicField.frame = CGRect(x: inset, y: y, width: width - inset * 2.0 - generateWidth - 4.0, height: 36.0)
            self.generateButton.frame = CGRect(x: width - inset - generateWidth, y: y, width: generateWidth, height: 36.0)
            self.generateButton.isEnabled = !self.busy
            y += 40.0
            if let status = self.statusLabel.text, !status.isEmpty {
                self.statusLabel.isHidden = false
                let h = ceil((status as NSString).boundingRect(with: CGSize(width: width - inset * 2.0, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: UIFont.systemFont(ofSize: 14.0)], context: nil).height)
                self.statusLabel.frame = CGRect(x: inset, y: y, width: width - inset * 2.0, height: h)
                y += h + 6.0
            } else {
                self.statusLabel.isHidden = true
            }
            for v in [self.draftView, self.scheduleButton, self.postButton] + self.editButtons as [UIView] {
                v.isHidden = !self.hasDraft
            }
            if self.hasDraft {
                let fitting = self.draftView.sizeThatFits(CGSize(width: width - inset * 2.0, height: .greatestFiniteMagnitude)).height
                let h = min(max(80.0, ceil(fitting)), 200.0)
                self.draftView.frame = CGRect(x: inset, y: y, width: width - inset * 2.0, height: h)
                self.draftView.isEditable = !self.busy
                y += h + 4.0
                var x = inset - 6.0
                for button in self.editButtons {
                    button.sizeToFit()
                    button.frame = CGRect(x: x, y: y, width: button.bounds.width + 12.0, height: 32.0)
                    button.isEnabled = !self.busy
                    x += button.bounds.width + 4.0
                }
                y += 34.0
                self.postButton.sizeToFit()
                let postWidth = max(80.0, self.postButton.bounds.width + 16.0)
                self.postButton.frame = CGRect(x: width - inset - postWidth, y: y, width: postWidth, height: 34.0)
                self.scheduleButton.sizeToFit()
                self.scheduleButton.frame = CGRect(x: self.postButton.frame.minX - self.scheduleButton.bounds.width - 20.0, y: y, width: self.scheduleButton.bounds.width + 12.0, height: 34.0)
                self.postButton.isEnabled = !self.busy
                self.scheduleButton.isEnabled = !self.busy
                y += 40.0
            }
            y += 4.0
            host.showPanel(self, height: y)
        }
    }
}
