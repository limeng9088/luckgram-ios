import Foundation
import UIKit
import SwiftSignalKit
import Display
import ComponentFlow
import TelegramCore
import TelegramPresentationData
import AccountContext

/// spec 19: state of the chat summary in one chat (bar, card, points, questions). Owned by the chat
/// screen; the header panel (`LuckgramChatSummaryPanelComponent`) renders it. Main thread only.
public final class LuckgramChatSummaryModel {
    /// spec 19 需求 1: the bar shows from this many unread messages.
    public static let barMinUnread = 30
    /// Largest range offered; also caps "unread".
    static let maxRange = 500

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiSummary)
    }

    public enum Phase: Equatable {
        case hidden
        case bar(unread: Int)
        case card
    }

    public struct QA {
        let question: String
        var answer: [[LuckgramChatSummaryLogic.Segment]]?
        var error: String?
    }

    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let threadId: Int64?
    /// Called after any change; the chat re-lays out its header panels.
    public var onChanged: (() -> Void)?
    /// Jumps to a message of this chat.
    public var jumpToMessage: ((EngineMessage.Id) -> Void)?
    /// Presents the AI consent alert.
    public var presentController: ((ViewController) -> Void)?

    public private(set) var phase: Phase = .hidden
    public private(set) var version = 0
    private(set) var title = ""
    private(set) var status: String?
    private(set) var retry: (() -> Void)?
    private(set) var points: [[LuckgramChatSummaryLogic.Segment]] = []
    private(set) var qa: [QA] = []
    var isCollapsed = false
    private(set) var isBusy = false
    private var unread = 0

    private var lines: [LuckgramChatSummaryLogic.Line] = []
    private(set) var validIds = Set<Int32>()
    private var disposable: Disposable?

    public init(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?) {
        self.context = context
        self.peerId = peerId
        self.threadId = threadId
    }

    deinit {
        self.disposable?.dispose()
    }

    private func changed() {
        self.version += 1
        self.onChanged?()
    }

    private var maxChars: Int {
        return LuckgramSettings.shared.remoteInt("ai.max_input_chars", default: 60000)
    }

    // MARK: - Bar and menu

    public func setUnread(_ count: Int) {
        self.unread = count
        if case .card = self.phase {
            return
        }
        let newPhase: Phase = (LuckgramChatSummaryModel.isEnabled && count >= LuckgramChatSummaryModel.barMinUnread) ? .bar(unread: count) : .hidden
        if newPhase != self.phase {
            self.phase = newPhase
            self.changed()
        }
    }

    func startUnread() {
        self.start(count: min(self.unread, LuckgramChatSummaryModel.maxRange), label: LuckgramStrings.pick("未读", "Unread"))
    }

    /// "总结聊天": pick the range.
    public func makeRangePicker() -> UIAlertController {
        let sheet = UIAlertController(title: LuckgramStrings.pick("总结聊天", "Summarize chat"), message: nil, preferredStyle: .actionSheet)
        if self.unread > 0 {
            let n = min(self.unread, LuckgramChatSummaryModel.maxRange)
            sheet.addAction(UIAlertAction(title: LuckgramStrings.pick("未读（\(n) 条）", "Unread (\(n))"), style: .default) { [weak self] _ in
                self?.startUnread()
            })
        }
        for n in [100, 300, 500] {
            let label = LuckgramStrings.pick("最近 \(n) 条", "Last \(n)")
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                self?.start(count: n, label: label)
            })
        }
        sheet.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel))
        return sheet
    }

    // MARK: - Summary

    func close() {
        self.disposable?.dispose()
        self.disposable = nil
        self.isBusy = false
        self.phase = .hidden
        self.changed()
    }

    func toggleCollapsed() {
        self.isCollapsed = !self.isCollapsed
        self.changed()
    }

    func start(count: Int, label: String) {
        self.disposable?.dispose()
        self.phase = .card
        self.isCollapsed = false
        self.title = LuckgramStrings.pick("AI 总结 · ", "AI summary · ") + label
        self.points = []
        self.qa = []
        self.isBusy = true
        self.status = LuckgramStrings.pick("正在读取消息…", "Reading messages…")
        self.retry = nil
        self.changed()

        let context = self.context
        let present: (ViewController) -> Void = { [weak self] c in
            self?.presentController?(c)
        }
        let maxChars = self.maxChars
        self.disposable = (self.load(count: count)
        |> deliverOnMainQueue
        |> mapToSignal { [weak self] lines -> Signal<String, LuckgramAIError> in
            guard let self else {
                return .complete()
            }
            self.lines = lines
            self.validIds = Set(lines.map { $0.id })
            if lines.isEmpty {
                return .single("")
            }
            self.status = LuckgramStrings.pick("正在总结 \(lines.count) 条消息…", "Summarizing \(lines.count) messages…")
            self.changed()
            let parts = LuckgramChatSummaryLogic.split(lines, maxChars: maxChars)
            return LuckgramChatSummaryModel.summarize(context: context, present: present, parts: parts, maxChars: maxChars)
        }
        |> deliverOnMainQueue).startStrict(next: { [weak self] text in
            guard let self else {
                return
            }
            self.isBusy = false
            if self.lines.isEmpty {
                self.status = LuckgramStrings.pick("没有可总结的文字消息", "No text messages to summarize")
            } else {
                self.status = nil
                self.points = LuckgramChatSummaryLogic.bullets(text).map { LuckgramChatSummaryLogic.parse($0, validIds: self.validIds) }
            }
            self.changed()
        }, error: { [weak self] error in
            self?.failed(error, retry: { [weak self] in
                self?.start(count: count, label: label)
            })
        })
    }

    private func failed(_ error: LuckgramAIError, retry: @escaping () -> Void) {
        self.isBusy = false
        if error.code == LuckgramAIError.consentDenied {
            self.close()
            return
        }
        self.status = error.localizedMessage + LuckgramStrings.pick(" 点此重试", " Tap to retry")
        self.retry = retry
        self.changed()
    }

    /// Parts are summarized one after another; more than one part is merged (spec 19 需求 5).
    private static func summarize(context: AccountContext, present: @escaping (ViewController) -> Void, parts: [String], maxChars: Int) -> Signal<String, LuckgramAIError> {
        func chat(_ content: String, task: LuckgramAI.AITask) -> Signal<String, LuckgramAIError> {
            return LuckgramAI.shared.chat(context: context, present: present, task: task, messages: [.user(content)], stream: false)
            |> mapToSignal { event -> Signal<String, LuckgramAIError> in
                if case let .completed(text) = event {
                    return .single(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return .complete()
            }
            |> take(1)
        }
        func run(_ index: Int, _ acc: [String]) -> Signal<[String], LuckgramAIError> {
            if index >= parts.count {
                return .single(acc)
            }
            return chat(parts[index], task: .summary)
            |> mapToSignal { text -> Signal<[String], LuckgramAIError> in
                return run(index + 1, acc + [text])
            }
        }
        return run(0, [])
        |> mapToSignal { partial -> Signal<String, LuckgramAIError> in
            if partial.count <= 1 {
                return .single(partial.first ?? "")
            }
            var merge = LuckgramChatSummaryLogic.header(merge: true)
            for (i, p) in partial.enumerated() {
                merge += "Part \(i + 1):\n\(p)\n\n"
            }
            if merge.unicodeScalars.count > maxChars {
                var scalars = String.UnicodeScalarView()
                scalars.append(contentsOf: merge.unicodeScalars.prefix(maxChars))
                merge = String(scalars)
            }
            return chat(merge, task: .summary)
        }
    }

    func ask(_ question: String) {
        if self.isBusy || self.lines.isEmpty {
            return
        }
        let tail = "\n\nQuestion: " + question + "\nAnswer briefly, in the language of the question. " + LuckgramChatSummaryLogic.citeRule
        let head = "Chat messages (oldest first):\n"
        let budget = max(1000, self.maxChars - tail.unicodeScalars.count - head.unicodeScalars.count - 100)
        var picked: [String] = []
        var size = 0
        for line in self.lines.reversed() {
            let s = LuckgramChatSummaryLogic.cut(line.format())
            let length = s.unicodeScalars.count + 1
            if size + length > budget {
                break
            }
            picked.insert(s, at: 0)
            size += length
        }
        self.qa.append(QA(question: question, answer: nil, error: nil))
        let index = self.qa.count - 1
        self.isBusy = true
        self.changed()
        let validIds = self.validIds
        self.disposable = (LuckgramAI.shared.chat(context: self.context, present: { [weak self] c in
            self?.presentController?(c)
        }, task: .chat, messages: [.user(head + picked.joined(separator: "\n") + tail)], stream: false)
        |> deliverOnMainQueue).startStrict(next: { [weak self] event in
            guard let self, case let .completed(text) = event, index < self.qa.count else {
                return
            }
            self.isBusy = false
            self.qa[index].answer = LuckgramChatSummaryLogic.bullets(text).map { LuckgramChatSummaryLogic.parse($0, validIds: validIds) }
            self.changed()
        }, error: { [weak self] error in
            guard let self, index < self.qa.count else {
                return
            }
            self.isBusy = false
            self.qa[index].error = error.localizedMessage
            self.changed()
        })
    }

    // MARK: - History

    /// The last `count` messages (oldest first), straight from Telegram; nothing is marked read.
    private func load(count: Int) -> Signal<[LuckgramChatSummaryLogic.Line], LuckgramAIError> {
        let context = self.context
        let peerId = self.peerId
        let threadId = self.threadId
        let accountPeerId = context.account.peerId
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let location: SearchMessagesLocation = .peer(peerId: peerId, fromId: nil, tags: nil, reactions: nil, threadId: threadId, minDate: nil, maxDate: nil)

        func page(_ state: SearchMessagesState?, _ acc: [EngineMessage]) -> Signal<[EngineMessage], NoError> {
            let remaining = count - acc.count
            if remaining <= 0 {
                return .single(acc)
            }
            return context.engine.messages.searchMessages(location: location, query: "", state: state, limit: Int32(min(100, remaining)))
            |> take(1)
            |> mapToSignal { result, newState -> Signal<[EngineMessage], NoError> in
                var known = Set(acc.map { $0.id })
                var next = acc
                for message in result.messages where !known.contains(message.id) {
                    known.insert(message.id)
                    next.append(EngineMessage(message))
                }
                if next.count == acc.count || result.completed {
                    return .single(next)
                }
                return page(newState, next)
            }
        }

        return page(nil, [])
        |> castError(LuckgramAIError.self)
        |> mapToSignal { messages -> Signal<[LuckgramChatSummaryLogic.Line], LuckgramAIError> in
            if messages.isEmpty {
                // Offline the search just returns nothing: report it as a network error.
                return context.account.networkState
                |> take(1)
                |> castError(LuckgramAIError.self)
                |> mapToSignal { state -> Signal<[LuckgramChatSummaryLogic.Line], LuckgramAIError> in
                    if case .online = state {
                        return .single([])
                    }
                    return .fail(LuckgramAIError(code: LuckgramAIError.networkError))
                }
            }
            let sorted = messages.sorted(by: { $0.id.id < $1.id.id }).prefix(count)
            var lines: [LuckgramChatSummaryLogic.Line] = []
            for message in sorted {
                let text = LuckgramChatSummaryModel.describe(message)
                if text.isEmpty {
                    continue
                }
                let sender: String
                if message.author?.id == accountPeerId {
                    sender = LuckgramStrings.pick("我", "Me")
                } else if let author = message.author {
                    sender = author.compactDisplayTitle
                } else {
                    sender = "?"
                }
                lines.append(LuckgramChatSummaryLogic.Line(id: message.id.id, sender: sender, time: formatter.string(from: Date(timeIntervalSince1970: Double(message.timestamp))), text: text))
            }
            return .single(lines)
        }
    }

    /// Text of a message, with media as a placeholder followed by its caption; service messages are skipped.
    static func describe(_ message: EngineMessage) -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var placeholder: String?
        for media in message.media {
            if media is TelegramMediaAction {
                return ""
            } else if media is TelegramMediaImage {
                placeholder = LuckgramStrings.pick("[图片]", "[Photo]")
            } else if let file = media as? TelegramMediaFile {
                if file.isVoice {
                    placeholder = LuckgramStrings.pick("[语音]", "[Voice message]")
                } else if file.isInstantVideo {
                    placeholder = LuckgramStrings.pick("[视频消息]", "[Video message]")
                } else if file.isSticker || file.isAnimatedSticker {
                    placeholder = LuckgramStrings.pick("[贴纸]", "[Sticker]")
                } else if file.isAnimated {
                    placeholder = "[GIF]"
                } else if file.isVideo {
                    placeholder = LuckgramStrings.pick("[视频]", "[Video]")
                } else if file.isMusic {
                    placeholder = LuckgramStrings.pick("[音乐]", "[Music]")
                } else {
                    placeholder = LuckgramStrings.pick("[文件", "[File") + (file.fileName.flatMap { " " + $0 } ?? "") + "]"
                }
            } else if media is TelegramMediaMap {
                placeholder = LuckgramStrings.pick("[位置]", "[Location]")
            } else if media is TelegramMediaContact {
                placeholder = LuckgramStrings.pick("[联系人]", "[Contact]")
            } else if let poll = media as? TelegramMediaPoll {
                placeholder = LuckgramStrings.pick("[投票] ", "[Poll] ") + poll.text
            }
        }
        guard let placeholder else {
            return text
        }
        return text.isEmpty ? placeholder : placeholder + " " + text
    }
}

/// spec 19: the header panel of a chat: the "N 条未读消息 · 总结" bar or the summary card.
public final class LuckgramChatSummaryPanelComponent: Component {
    let model: LuckgramChatSummaryModel
    let version: Int
    let theme: PresentationTheme

    public init(model: LuckgramChatSummaryModel, theme: PresentationTheme) {
        self.model = model
        self.version = model.version
        self.theme = theme
    }

    public static func ==(lhs: LuckgramChatSummaryPanelComponent, rhs: LuckgramChatSummaryPanelComponent) -> Bool {
        return lhs.model === rhs.model && lhs.version == rhs.version && lhs.theme === rhs.theme
    }

    public final class View: UIView, UITextViewDelegate, UITextFieldDelegate {
        private var component: LuckgramChatSummaryPanelComponent?
        private let barButton = UIButton(type: .system)
        private let titleLabel = UILabel()
        private let collapseButton = UIButton(type: .system)
        private let closeButton = UIButton(type: .system)
        private let scrollView = UIScrollView()
        private let statusButton = UIButton(type: .system)
        private let textView = UITextView()
        private let disclaimer = UILabel()
        private let questionField = UITextField()
        private let askButton = UIButton(type: .system)
        private let separator = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.clipsToBounds = true
            self.barButton.titleLabel?.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            self.barButton.addTarget(self, action: #selector(self.barPressed), for: .touchUpInside)
            self.titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
            self.collapseButton.addTarget(self, action: #selector(self.collapsePressed), for: .touchUpInside)
            self.closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold)), for: .normal)
            self.closeButton.accessibilityLabel = LuckgramStrings.pick("关闭", "Close")
            self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
            self.statusButton.titleLabel?.font = UIFont.systemFont(ofSize: 14.0)
            self.statusButton.titleLabel?.numberOfLines = 0
            self.statusButton.contentHorizontalAlignment = .leading
            self.statusButton.addTarget(self, action: #selector(self.statusPressed), for: .touchUpInside)
            self.textView.isEditable = false
            self.textView.isScrollEnabled = false
            self.textView.backgroundColor = .clear
            self.textView.textContainerInset = .zero
            self.textView.textContainer.lineFragmentPadding = 0.0
            self.textView.delegate = self
            self.disclaimer.font = UIFont.systemFont(ofSize: 12.0)
            self.disclaimer.text = LuckgramStrings.pick("AI 生成，可能有误", "AI-generated, may be inaccurate")
            self.questionField.font = UIFont.systemFont(ofSize: 15.0)
            self.questionField.placeholder = LuckgramStrings.pick("问这些消息…", "Ask about these messages…")
            self.questionField.returnKeyType = .send
            self.questionField.delegate = self
            self.questionField.borderStyle = .none
            self.questionField.layer.cornerRadius = 16.0
            self.questionField.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 12.0, height: 1.0))
            self.questionField.leftViewMode = .always
            self.askButton.setImage(UIImage(systemName: "arrow.up.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26.0)), for: .normal)
            self.askButton.accessibilityLabel = LuckgramStrings.pick("发送", "Send")
            self.askButton.addTarget(self, action: #selector(self.askPressed), for: .touchUpInside)
            for v in [self.barButton, self.titleLabel, self.collapseButton, self.closeButton, self.scrollView, self.questionField, self.askButton, self.separator] as [UIView] {
                self.addSubview(v)
            }
            for v in [self.statusButton, self.textView, self.disclaimer] as [UIView] {
                self.scrollView.addSubview(v)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func barPressed() {
            self.component?.model.startUnread()
        }

        @objc private func collapsePressed() {
            self.component?.model.toggleCollapsed()
        }

        @objc private func closePressed() {
            self.questionField.resignFirstResponder()
            self.component?.model.close()
        }

        @objc private func statusPressed() {
            self.component?.model.retry?()
        }

        @objc private func askPressed() {
            let text = (self.questionField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let model = self.component?.model, !model.isBusy else {
                return
            }
            self.questionField.text = ""
            model.ask(text)
        }

        public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            self.askPressed()
            return false
        }

        public func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if url.scheme == "luckgram-ref", let host = url.host, let id = Int32(host), let model = self.component?.model, model.validIds.contains(id) {
                model.jumpToMessage?(EngineMessage.Id(peerId: model.peerIdValue, namespace: Namespaces.Message.Cloud, id: id))
                return false
            }
            return false
        }

        private func render(_ points: [[LuckgramChatSummaryLogic.Segment]], bulleted: Bool, font: UIFont, color: UIColor, link: UIColor, into out: NSMutableAttributedString, ref: inout Int) {
            for (i, segments) in points.enumerated() {
                if out.length > 0 || i > 0 {
                    out.append(NSAttributedString(string: "\n"))
                }
                if bulleted {
                    out.append(NSAttributedString(string: "• ", attributes: [.font: font, .foregroundColor: color]))
                }
                for segment in segments {
                    switch segment {
                    case let .text(text):
                        out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
                    case let .reference(id):
                        ref += 1
                        out.append(NSAttributedString(string: " ", attributes: [.font: font]))
                        out.append(NSAttributedString(string: "[\(ref)]", attributes: [.font: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold), .foregroundColor: link, .link: URL(string: "luckgram-ref://\(id)")!]))
                    }
                }
            }
        }

        func update(component: LuckgramChatSummaryPanelComponent, availableSize: CGSize) -> CGSize {
            self.component = component
            let model = component.model
            let theme = component.theme
            let width = availableSize.width
            let primary = theme.rootController.navigationBar.primaryTextColor
            let secondary = theme.rootController.navigationBar.secondaryTextColor
            let accent = theme.rootController.navigationBar.accentTextColor
            self.separator.backgroundColor = theme.rootController.navigationBar.separatorColor

            switch model.phase {
            case .hidden:
                return CGSize(width: width, height: 0.0)
            case let .bar(unread):
                for v in [self.titleLabel, self.collapseButton, self.closeButton, self.scrollView, self.questionField, self.askButton] as [UIView] {
                    v.isHidden = true
                }
                self.barButton.isHidden = false
                self.barButton.setTitle(LuckgramStrings.pick("\(unread) 条未读消息 · 总结", "\(unread) unread messages · Summarize"), for: .normal)
                self.barButton.tintColor = accent
                self.barButton.frame = CGRect(x: 0.0, y: 0.0, width: width, height: 40.0)
                self.separator.frame = CGRect(x: 0.0, y: 40.0 - 1.0 / UIScreen.main.scale, width: width, height: 1.0 / UIScreen.main.scale)
                return CGSize(width: width, height: 40.0)
            case .card:
                break
            }
            self.barButton.isHidden = true
            self.titleLabel.isHidden = false
            self.collapseButton.isHidden = false
            self.closeButton.isHidden = false
            self.titleLabel.text = model.title
            self.titleLabel.textColor = primary
            self.collapseButton.tintColor = secondary
            self.closeButton.tintColor = secondary
            self.collapseButton.setImage(UIImage(systemName: model.isCollapsed ? "chevron.down" : "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold)), for: .normal)
            self.collapseButton.accessibilityLabel = model.isCollapsed ? LuckgramStrings.pick("展开", "Expand") : LuckgramStrings.pick("收起", "Collapse")

            let inset: CGFloat = 14.0
            self.titleLabel.frame = CGRect(x: inset, y: 0.0, width: width - inset - 84.0, height: 40.0)
            self.collapseButton.frame = CGRect(x: width - 84.0, y: 0.0, width: 40.0, height: 40.0)
            self.closeButton.frame = CGRect(x: width - 44.0, y: 0.0, width: 40.0, height: 40.0)
            var y: CGFloat = 40.0

            let expanded = !model.isCollapsed
            self.scrollView.isHidden = !expanded
            self.questionField.isHidden = !expanded
            self.askButton.isHidden = !expanded
            if expanded {
                let contentWidth = width - inset * 2.0
                var contentY: CGFloat = 0.0
                if let status = model.status {
                    self.statusButton.isHidden = false
                    self.statusButton.setTitle(status, for: .normal)
                    self.statusButton.setTitleColor(model.retry != nil ? accent : secondary, for: .normal)
                    let h = ceil((status as NSString).boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: UIFont.systemFont(ofSize: 14.0)], context: nil).height) + 6.0
                    self.statusButton.frame = CGRect(x: inset, y: contentY, width: contentWidth, height: h)
                    contentY += h
                } else {
                    self.statusButton.isHidden = true
                }
                let text = NSMutableAttributedString()
                var ref = 0
                let font = UIFont.systemFont(ofSize: 15.0)
                self.render(model.points, bulleted: model.points.count > 1, font: font, color: primary, link: accent, into: text, ref: &ref)
                for item in model.qa {
                    text.append(NSAttributedString(string: (text.length > 0 ? "\n\n" : "") + LuckgramStrings.pick("问：", "Q: ") + item.question + "\n", attributes: [.font: UIFont.systemFont(ofSize: 15.0, weight: .semibold), .foregroundColor: primary]))
                    if let answer = item.answer {
                        let answerText = NSMutableAttributedString()
                        self.render(answer, bulleted: answer.count > 1, font: font, color: primary, link: accent, into: answerText, ref: &ref)
                        text.append(answerText)
                    } else if let error = item.error {
                        text.append(NSAttributedString(string: error, attributes: [.font: font, .foregroundColor: theme.list.itemDestructiveColor]))
                    } else {
                        text.append(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: secondary]))
                    }
                }
                self.textView.attributedText = text
                self.textView.linkTextAttributes = [.foregroundColor: accent]
                self.textView.isHidden = text.length == 0
                if text.length > 0 {
                    let h = ceil(self.textView.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
                    self.textView.frame = CGRect(x: inset, y: contentY, width: contentWidth, height: h)
                    contentY += h + 4.0
                }
                self.disclaimer.textColor = secondary
                self.disclaimer.frame = CGRect(x: inset, y: contentY, width: contentWidth, height: 16.0)
                contentY += 20.0
                let screenHeight = UIScreen.main.bounds.height
                let visible = min(contentY, floor(screenHeight * 0.4))
                let wasAtBottom = self.scrollView.contentOffset.y + self.scrollView.bounds.height >= self.scrollView.contentSize.height - 4.0
                self.scrollView.frame = CGRect(x: 0.0, y: y, width: width, height: visible)
                self.scrollView.contentSize = CGSize(width: width, height: contentY)
                if wasAtBottom && contentY > visible {
                    self.scrollView.contentOffset = CGPoint(x: 0.0, y: contentY - visible)
                }
                y += visible

                self.questionField.backgroundColor = theme.chat.inputPanel.inputBackgroundColor
                self.questionField.textColor = theme.chat.inputPanel.inputTextColor
                self.questionField.frame = CGRect(x: inset, y: y + 6.0, width: width - inset - 52.0, height: 34.0)
                self.askButton.tintColor = theme.chat.inputPanel.actionControlFillColor
                self.askButton.isEnabled = !model.isBusy
                self.askButton.frame = CGRect(x: width - 46.0, y: y + 3.0, width: 40.0, height: 40.0)
                y += 46.0
            }
            self.separator.frame = CGRect(x: 0.0, y: y - 1.0 / UIScreen.main.scale, width: width, height: 1.0 / UIScreen.main.scale)
            return CGSize(width: width, height: y)
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize)
    }
}

extension LuckgramChatSummaryModel {
    var peerIdValue: EnginePeer.Id {
        return self.peerId
    }
}
