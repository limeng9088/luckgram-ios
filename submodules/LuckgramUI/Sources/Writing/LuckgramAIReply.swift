import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext

/// spec 20: "帮我回复" in the ✦ menu of the message field (registered through 21's extension point).
/// Sends the chat's last 20 messages and the draft with `task=reply`; the three candidates appear
/// one by one in a panel above the field; tapping one replaces the field's text (undoable).
public enum LuckgramAIReply {
    /// spec 20 需求 2
    static let contextMessages = 20
    static let maxMessageChars = 1000

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiReply)
    }

    /// The registration line used by `LuckgramAIWritingFeatures`.
    static var menuItem: LuckgramAIWriting.MenuItem {
        return .init(id: "ai_reply", title: ("帮我回复", "Help me reply"), icon: "arrowshape.turn.up.left", order: 0, allowsEmptyText: true, isVisible: { peer in
            return LuckgramAIReply.isEnabled && peer != nil
        }, action: { host in
            ReplyPanel(host: host).show()
        })
    }

    static func prompt(transcript: String, draft: String, me: String) -> String {
        var s = "Recent messages (oldest first; \"\(me)\" is me):\n"
        s += transcript.isEmpty ? "(none)" : transcript
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            s += "\n\nMy draft: " + trimmed
        } else {
            s += "\n\nI have no draft; suggest what I could reply."
        }
        return s
    }

    /// The candidates in streamed text: complete lines, plus the line being written.
    static func candidates(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "^(\\d[.)、]|[-•*])\\s*", options: .regularExpression) {
                line = String(line[range.upperBound...])
            }
            if line.count >= 2, (line.hasPrefix("\"") && line.hasSuffix("\"")) || (line.hasPrefix("“") && line.hasSuffix("”")) {
                line = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty {
                out.append(line)
            }
            if out.count == 3 {
                break
            }
        }
        return out
    }

    /// The chat's last messages, oldest first, as "name: text" lines.
    static func transcript(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?) -> Signal<String, NoError> {
        let me = LuckgramStrings.pick("我", "Me")
        let accountPeerId = context.account.peerId
        return context.engine.messages.searchMessages(location: .peer(peerId: peerId, fromId: nil, tags: nil, reactions: nil, threadId: threadId, minDate: nil, maxDate: nil), query: "", state: nil, limit: Int32(self.contextMessages))
        |> take(1)
        |> map { result, _ -> String in
            let messages = result.messages.map(EngineMessage.init).sorted(by: { $0.id.id < $1.id.id }).suffix(self.contextMessages)
            var lines: [String] = []
            for message in messages {
                var text = message.text
                if text.isEmpty {
                    if message.media.contains(where: { $0 is TelegramMediaAction }) {
                        continue
                    } else if message.media.contains(where: { $0 is TelegramMediaImage }) {
                        text = LuckgramStrings.pick("[图片]", "[Photo]")
                    } else if let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile {
                        if file.isVoice {
                            text = LuckgramStrings.pick("[语音]", "[Voice message]")
                        } else if file.isVideo || file.isInstantVideo {
                            text = LuckgramStrings.pick("[视频]", "[Video]")
                        } else if file.isSticker || file.isAnimatedSticker {
                            text = LuckgramStrings.pick("[贴纸]", "[Sticker]")
                        } else {
                            text = LuckgramStrings.pick("[文件]", "[File]")
                        }
                    } else {
                        continue
                    }
                }
                if text.count > self.maxMessageChars {
                    text = String(text.prefix(self.maxMessageChars)) + "…"
                }
                let name = message.author?.id == accountPeerId ? me : (message.author?.compactDisplayTitle ?? "?")
                lines.append(name + ": " + text.replacingOccurrences(of: "\n", with: " "))
            }
            return lines.joined(separator: "\n")
        }
    }

    private final class ReplyPanel: UIView {
        private weak var host: LuckgramAIWritingHost?
        private let titleLabel = UILabel()
        private let undoButton = UIButton(type: .system)
        private let againButton = UIButton(type: .system)
        private let closeButton = UIButton(type: .system)
        private let statusLabel = UILabel()
        private var rows: [UIButton] = []
        private var candidates: [String] = []
        private var draft = ""
        private var picked = false
        private var disposable: Disposable?

        init(host: LuckgramAIWritingHost) {
            self.host = host
            super.init(frame: .zero)
            self.titleLabel.text = LuckgramStrings.pick("帮我回复", "Help me reply")
            self.titleLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            self.titleLabel.textColor = .secondaryLabel
            self.undoButton.setTitle(LuckgramStrings.pick("撤销", "Undo"), for: .normal)
            self.undoButton.isHidden = true
            self.undoButton.addTarget(self, action: #selector(self.undoPressed), for: .touchUpInside)
            self.againButton.setTitle(LuckgramStrings.pick("换一批", "Try again"), for: .normal)
            self.againButton.addTarget(self, action: #selector(self.againPressed), for: .touchUpInside)
            self.closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            self.closeButton.accessibilityLabel = LuckgramStrings.pick("关闭", "Close")
            self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
            for button in [self.undoButton, self.againButton] {
                button.titleLabel?.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
            }
            self.statusLabel.font = UIFont.systemFont(ofSize: 14.0)
            self.statusLabel.textColor = .secondaryLabel
            self.statusLabel.numberOfLines = 0
            for v in [self.titleLabel, self.undoButton, self.againButton, self.closeButton, self.statusLabel] as [UIView] {
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
            guard let host = self.host else {
                return
            }
            self.draft = host.text
            self.relayout()
            self.generate()
        }

        @objc private func undoPressed() {
            self.host?.undo()
            self.picked = false
            self.undoButton.isHidden = true
            self.relayout()
        }

        @objc private func againPressed() {
            self.generate()
        }

        @objc private func closePressed() {
            self.disposable?.dispose()
            self.host?.hidePanel(self)
        }

        private func generate() {
            guard let host = self.host, let peerId = host.peerId else {
                return
            }
            self.candidates = []
            self.statusLabel.text = LuckgramStrings.pick("正在生成…", "Writing…")
            self.againButton.isEnabled = false
            self.relayout()
            let context = host.context
            let draft = self.draft
            self.disposable?.dispose()
            self.disposable = (LuckgramAIReply.transcript(context: context, peerId: peerId, threadId: host.threadId)
            |> castError(LuckgramAIError.self)
            |> mapToSignal { transcript -> Signal<LuckgramAI.ChatEvent, LuckgramAIError> in
                let content = LuckgramAIReply.prompt(transcript: transcript, draft: draft, me: LuckgramStrings.pick("我", "Me"))
                return LuckgramAI.shared.chat(context: context, present: { [weak host] c in
                    host?.present(c)
                }, task: .reply, messages: [.user(content)], stream: true)
            }
            |> deliverOnMainQueue).startStrict(next: { [weak self] event in
                guard let self else {
                    return
                }
                switch event {
                case let .delta(_, text):
                    self.candidates = LuckgramAIReply.candidates(text)
                case let .completed(text):
                    self.candidates = LuckgramAIReply.candidates(text)
                    self.againButton.isEnabled = true
                    if self.candidates.isEmpty {
                        self.statusLabel.text = LuckgramStrings.pick("没有生成回复，请换一批", "No replies. Please try again")
                    }
                }
                self.relayout()
            }, error: { [weak self] error in
                guard let self else {
                    return
                }
                self.againButton.isEnabled = true
                if error.code == LuckgramAIError.consentDenied {
                    self.host?.hidePanel(self)
                    return
                }
                self.candidates = []
                self.statusLabel.text = error.localizedMessage
                self.relayout()
            })
        }

        @objc private func rowPressed(_ sender: UIButton) {
            guard sender.tag < self.candidates.count, let host = self.host else {
                return
            }
            // spec 20 需求 3: replaces the field (undo restores the draft), never sends
            host.setText(self.candidates[sender.tag], undoable: !self.picked)
            self.picked = true
            self.undoButton.isHidden = false
            self.relayout()
        }

        private func relayout() {
            guard let host = self.host else {
                return
            }
            let width = max(200.0, (self.superview?.bounds.width ?? UIScreen.main.bounds.width - 16.0))
            var y: CGFloat = 0.0
            self.titleLabel.frame = CGRect(x: 14.0, y: 0.0, width: 140.0, height: 40.0)
            self.closeButton.frame = CGRect(x: width - 40.0, y: 0.0, width: 40.0, height: 40.0)
            self.againButton.sizeToFit()
            self.againButton.frame = CGRect(x: self.closeButton.frame.minX - self.againButton.bounds.width - 8.0, y: 0.0, width: self.againButton.bounds.width, height: 40.0)
            self.undoButton.sizeToFit()
            self.undoButton.frame = CGRect(x: self.againButton.frame.minX - self.undoButton.bounds.width - 12.0, y: 0.0, width: self.undoButton.bounds.width, height: 40.0)
            y = 40.0
            let font = UIFont.systemFont(ofSize: 15.0)
            if self.candidates.isEmpty {
                self.statusLabel.isHidden = false
                let h = ceil(((self.statusLabel.text ?? "") as NSString).boundingRect(with: CGSize(width: width - 28.0, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: self.statusLabel.font as Any], context: nil).height)
                self.statusLabel.frame = CGRect(x: 14.0, y: y, width: width - 28.0, height: h)
                y += h + 10.0
            } else {
                self.statusLabel.isHidden = true
            }
            while self.rows.count < self.candidates.count {
                let row = UIButton(type: .system)
                row.contentHorizontalAlignment = .leading
                row.titleLabel?.numberOfLines = 0
                row.titleLabel?.font = font
                row.setTitleColor(.label, for: .normal)
                row.tag = self.rows.count
                row.addTarget(self, action: #selector(self.rowPressed(_:)), for: .touchUpInside)
                self.addSubview(row)
                self.rows.append(row)
            }
            for (i, row) in self.rows.enumerated() {
                if i < self.candidates.count {
                    row.isHidden = false
                    row.setTitle(self.candidates[i], for: .normal)
                    let h = ceil((self.candidates[i] as NSString).boundingRect(with: CGSize(width: width - 28.0, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil).height) + 16.0
                    row.frame = CGRect(x: 14.0, y: y, width: width - 28.0, height: h)
                    y += h
                } else {
                    row.isHidden = true
                }
            }
            y += 6.0
            host.showPanel(self, height: y)
        }
    }
}
