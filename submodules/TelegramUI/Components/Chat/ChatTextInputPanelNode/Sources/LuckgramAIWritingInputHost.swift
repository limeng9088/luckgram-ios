import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatPresentationInterfaceState
import UndoUI
import LuckgramUI
import TextFormat
import ChatControllerInteraction

/// spec 21: the message field as seen by AI writing and the features that extend it (20, 24): the
/// ✦ menu, the five effects streamed back into the field, undo, and the panel above the field.
final class LuckgramAIWritingInputHost: LuckgramAIWritingHost, LuckgramAIWritingEffectRunner {
    private weak var node: ChatTextInputPanelNode?
    let context: AccountContext
    private var undoState: ChatTextInputState?
    private var disposable: Disposable?

    init(node: ChatTextInputPanelNode, context: AccountContext) {
        self.node = node
        self.context = context
    }

    deinit {
        self.disposable?.dispose()
    }

    private var interfaceState: ChatPresentationInterfaceState? {
        return self.node?.luckgramInterfaceState
    }

    var peerId: EnginePeer.Id? {
        return self.interfaceState?.chatLocation.peerId
    }

    var threadId: Int64? {
        return self.interfaceState?.chatLocation.threadId
    }

    var peer: EnginePeer? {
        return self.interfaceState?.renderedPeer?.peer.flatMap(EnginePeer.init)
    }

    var isChannel: Bool {
        return LuckgramAIWriting.isBroadcastChannel(self.peer)
    }

    var canPostInChannel: Bool {
        return LuckgramAIWriting.canPostInChannel(self.peer)
    }

    var text: String {
        return self.interfaceState?.interfaceState.composeInputState.inputText.string ?? ""
    }

    private func replaceText(_ text: String) {
        self.node?.interfaceInteraction?.updateTextInputStateAndMode { _, inputMode in
            return (ChatTextInputState(inputText: NSAttributedString(string: text)), inputMode)
        }
    }

    func setText(_ text: String, undoable: Bool) {
        if undoable, let current = self.interfaceState?.interfaceState.composeInputState {
            self.undoState = current
        }
        self.replaceText(text)
        self.node?.ensureFocused()
    }

    var canUndo: Bool {
        return self.undoState != nil
    }

    func undo() {
        guard let state = self.undoState else {
            return
        }
        self.undoState = nil
        self.node?.interfaceInteraction?.updateTextInputStateAndMode { _, inputMode in
            return (state, inputMode)
        }
    }

    func showPanel(_ view: UIView, height: CGFloat) {
        self.node?.luckgramShowPanel(view, height: height)
    }

    func hidePanel(_ view: UIView) {
        self.node?.luckgramHidePanel(view)
    }

    func present(_ controller: UIViewController) {
        if let controller = controller as? ViewController {
            self.node?.interfaceInteraction?.presentController(controller, nil)
        } else {
            self.context.sharedContext.mainWindow?.presentNative(controller)
        }
    }

    func send(_ text: String, schedule: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return
        }
        self.undoState = nil
        self.replaceText(trimmed)
        // Let the chat take the new field state first, then use its own send path.
        DispatchQueue.main.async { [weak self] in
            guard let interaction = self?.node?.chatControllerInteraction else {
                return
            }
            if schedule {
                interaction.scheduleCurrentMessage(nil)
            } else {
                interaction.sendCurrentMessage(false, nil)
            }
        }
    }

    func showMenu() {
        guard let menu = LuckgramAIWriting.makeMenu(host: self) else {
            return
        }
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        menu.overrideUserInterfaceStyle = presentationData.theme.overallDarkAppearance ? .dark : .light
        if let popover = menu.popoverPresentationController, let view = self.node?.view {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.maxX - 60.0, y: 0.0, width: 1.0, height: 1.0)
        }
        self.context.sharedContext.mainWindow?.presentNative(menu)
    }

    // MARK: - Formatting

    /// Attributes the field keeps across a rewrite (spec 21 review P2): style, mentions by name, links, custom emoji.
    private static let keptAttributes: [NSAttributedString.Key] = [
        ChatTextInputAttributes.bold, ChatTextInputAttributes.italic, ChatTextInputAttributes.monospace,
        ChatTextInputAttributes.strikethrough, ChatTextInputAttributes.underline, ChatTextInputAttributes.spoiler,
        ChatTextInputAttributes.textMention, ChatTextInputAttributes.textUrl, ChatTextInputAttributes.customEmoji
    ]

    /// The AI works on plain text; puts the original's formatting back where its text survived.
    static func withFormatting(_ before: NSAttributedString, result: String) -> NSAttributedString {
        var runs: [(key: NSAttributedString.Key, value: Any, range: NSRange)] = []
        for key in keptAttributes {
            before.enumerateAttribute(key, in: NSRange(location: 0, length: before.length), options: []) { value, range, _ in
                if let value {
                    runs.append((key, value, range))
                }
            }
        }
        let out = NSMutableAttributedString(string: result)
        if runs.isEmpty {
            return out
        }
        let starts = LuckgramAIWritingEntities.relocate(original: before.string, ranges: runs.map { $0.range }, result: result)
        for (i, run) in runs.enumerated() {
            if let start = starts[i] {
                out.addAttribute(run.key, value: run.value, range: NSRange(location: start, length: run.range.length))
            }
        }
        return out
    }

    // MARK: - Effects

    func runWritingEffect(_ effect: String, done: String) {
        let original = self.text
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        if original.count > LuckgramAIWriting.maxChars {
            self.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: LuckgramStrings.pick("文字太长（超过 \(LuckgramAIWriting.maxChars) 字），请缩短后再试", "The text is too long (over \(LuckgramAIWriting.maxChars) characters). Please shorten it."), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
            return
        }
        guard let before = self.interfaceState?.interfaceState.composeInputState else {
            return
        }
        // spec 21 需求 2: the original is dimmed while the result is generated
        self.node?.luckgramSetGenerating(true)
        var started = false
        self.disposable?.dispose()
        self.disposable = (LuckgramAI.shared.chat(context: self.context, present: { [weak self] c in
            self?.present(c)
        }, task: .writing, effect: effect, messages: [.user(original)], stream: true)
        |> deliverOnMainQueue).startStrict(next: { [weak self] event in
            guard let self else {
                return
            }
            switch event {
            case let .delta(_, text):
                if !started {
                    started = true
                    self.node?.luckgramSetGenerating(false)
                }
                self.replaceText(text)
            case let .completed(text):
                self.node?.luckgramSetGenerating(false)
                let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isEmpty {
                    self.node?.interfaceInteraction?.updateTextInputStateAndMode { _, inputMode in
                        return (before, inputMode)
                    }
                    return
                }
                let formatted = LuckgramAIWritingInputHost.withFormatting(before.inputText, result: result)
                self.node?.interfaceInteraction?.updateTextInputStateAndMode { _, inputMode in
                    return (ChatTextInputState(inputText: formatted), inputMode)
                }
                self.undoState = before
                self.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: done, timeout: 8.0, customUndoText: LuckgramStrings.pick("撤销", "Undo")), elevatedLayout: false, action: { [weak self] action in
                    if case .undo = action {
                        self?.undo()
                    }
                    return true
                }))
            }
        }, error: { [weak self] error in
            guard let self else {
                return
            }
            self.node?.luckgramSetGenerating(false)
            self.node?.interfaceInteraction?.updateTextInputStateAndMode { _, inputMode in
                return (before, inputMode)
            }
            if error.code != LuckgramAIError.consentDenied {
                LuckgramAI.showError(error, context: self.context, present: { [weak self] c in
                    self?.present(c)
                })
            }
        })
    }
}
