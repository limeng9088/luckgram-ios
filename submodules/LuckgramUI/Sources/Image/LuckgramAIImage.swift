import Foundation
import UIKit
import Photos
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext

/// spec 23: AI images in the AI assistant, entirely through 18's extension points — the "画图" quick
/// button, an input interceptor for "画" and "/image", and the `image` message type. Images are kept
/// in the conversation's own folder (removed with it and with the account's data).
public enum LuckgramAIImage {
    static let type = "image"
    private static let statePending = "pending"
    private static let stateDone = "done"
    private static let stateError = "error"

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiImage)
    }

    /// spec 23 平台入口提示: the one registration line, called from the AI assistant's registry.
    static func register() {
        LuckgramAIRegistry.registerQuickAction(.init(id: "image", title: ("画图", "Draw"), icon: "paintbrush", isVisible: { LuckgramAIImage.isEnabled }, action: { host in
            host.inputText = LuckgramStrings.pick("画 ", "/image ")
        }))
        LuckgramAIRegistry.registerInputInterceptor(prefixes: ["/image", "画"], handler: { host, prefix, rest in
            if !LuckgramAIImage.isEnabled || rest.isEmpty {
                return false
            }
            host.addMessage(LuckgramAIConversation.Message(role: LuckgramAIConversation.Message.roleUser, text: prefix + " " + rest))
            LuckgramAIImage.generate(host: host, prompt: rest)
            return true
        })
        LuckgramAIRegistry.registerMessageType(self.type, renderer: Renderer())
    }

    /// Adds an image message and draws `prompt` into it.
    static func generate(host: LuckgramAIChatHost, prompt: String) {
        let message = LuckgramAIConversation.Message(role: LuckgramAIConversation.Message.roleAssistant, type: self.type, text: prompt)
        message.data = ["state": self.statePending]
        host.addMessage(message)
        let context = host.context
        let folder = LuckgramAIStore.shared(context: context).conversationDirectory(host.conversation.id)
        let _ = (LuckgramAI.shared.image(context: context, present: { c in
            context.sharedContext.mainWindow?.present(c, on: .root)
        }, prompt: prompt)
        |> deliverOnMainQueue).startStandalone(next: { [weak host] image in
            let ext = image.mimeType.contains("jpeg") ? "jpg" : (image.mimeType.contains("webp") ? "webp" : "png")
            let path = folder + "/" + message.id + "." + ext
            if let data = image.data, (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
                message.data = ["state": LuckgramAIImage.stateDone, "path": path]
            } else {
                message.data = ["state": LuckgramAIImage.stateError, "error": LuckgramAIError.upstreamUnavailable]
            }
            host?.updateMessage(message)
        }, error: { [weak host] error in
            message.data = ["state": LuckgramAIImage.stateError, "error": error.code]
            host?.updateMessage(message)
        })
    }

    static func errorText(_ code: String) -> String {
        if code == LuckgramAIError.contentRejected {
            // spec 23 需求 5
            return LuckgramStrings.pick("这个描述无法生成图片，换个说法试试", "This description can't be drawn. Try wording it differently.")
        }
        return LuckgramStrings.errorMessage(code)
    }

    /// spec 23 需求 3: Telegram's own share screen, sent as a normal photo. The AI page is a
    /// full-screen modal, so it is closed first and the share screen opens over the chat list.
    static func sendTo(host: LuckgramAIChatHost, path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = UIImage(data: data) else {
            return
        }
        let context = host.context
        let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data, synchronous: true)
        let dimensions = PixelDimensions(width: Int32(image.size.width * image.scale), height: Int32(image.size.height * image.scale))
        let representation = TelegramMediaImageRepresentation(dimensions: dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil)
        let subject: ShareControllerSubject = .image([ImageRepresentationWithReference(representation: representation, reference: .standalone(resource: resource))])
        let presentShare = {
            let share = context.sharedContext.makeShareScreen(context: context, params: ShareControllerParams(subject: subject, externalShare: false))
            context.sharedContext.mainWindow?.present(share, on: .root)
        }
        if let presenting = host.viewController.navigationController?.presentingViewController {
            presenting.dismiss(animated: true, completion: presentShare)
        } else {
            presentShare()
        }
    }

    static func save(host: LuckgramAIChatHost, path: String) {
        let controller = host.viewController
        let done: (Bool) -> Void = { ok in
            let alert = UIAlertController(title: nil, message: ok ? LuckgramStrings.pick("已保存到相册", "Saved to Photos") : LuckgramStrings.pick("无法保存，请在系统设置中允许 Luckgram 访问照片。", "Couldn't save. Please allow Luckgram to add photos in Settings."), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: LuckgramStrings.pick("好", "OK"), style: .default))
            controller.present(alert, animated: true)
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    done(false)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: URL(fileURLWithPath: path))
            }, completionHandler: { ok, _ in
                DispatchQueue.main.async {
                    done(ok)
                }
            })
        }
    }

    /// The image bubble: placeholder while drawing, then the picture with 发送给… / 保存 / 重画.
    private final class Renderer: LuckgramAIMessageRenderer {
        static let imageSide: CGFloat = 240.0

        func makeView() -> UIView {
            return ImageBubble(frame: .zero)
        }

        func update(view: UIView, message: LuckgramAIConversation.Message, isOutgoing: Bool, maxWidth: CGFloat) {
            (view as? ImageBubble)?.update(message: message, side: min(Renderer.imageSide, maxWidth))
        }

        func size(message: LuckgramAIConversation.Message, maxWidth: CGFloat) -> CGSize {
            let side = min(Renderer.imageSide, maxWidth)
            let state = message.data?["state"] ?? LuckgramAIImage.statePending
            let textHeight = ImageBubble.textHeight(ImageBubble.statusText(message), width: side)
            if state == LuckgramAIImage.stateError {
                return CGSize(width: side, height: textHeight + 4.0 + 36.0)
            }
            let actions: CGFloat = state == LuckgramAIImage.stateDone ? 36.0 : 0.0
            return CGSize(width: side, height: side + 6.0 + textHeight + actions)
        }

        func contextText(_ message: LuckgramAIConversation.Message) -> String? {
            return nil // images are not sent to the chat model
        }

        func copyText(_ message: LuckgramAIConversation.Message) -> String? {
            return message.text
        }
    }

    private final class ImageBubble: UIView {
        private let imageView = UIImageView()
        private let spinner = UIActivityIndicatorView(style: .medium)
        private let statusLabel = UILabel()
        private let sendButton = UIButton(type: .system)
        private let saveButton = UIButton(type: .system)
        private let redrawButton = UIButton(type: .system)
        private var message: LuckgramAIConversation.Message?
        private var loadedPath: String?

        static let font = UIFont.systemFont(ofSize: 14.0)

        static func statusText(_ message: LuckgramAIConversation.Message) -> String {
            switch message.data?["state"] ?? LuckgramAIImage.statePending {
            case LuckgramAIImage.stateDone:
                return message.text ?? ""
            case LuckgramAIImage.stateError:
                return LuckgramAIImage.errorText(message.data?["error"] ?? LuckgramAIError.upstreamUnavailable)
            default:
                return LuckgramStrings.pick("正在画…", "Drawing…")
            }
        }

        static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
            return ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: self.font], context: nil).height)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.imageView.contentMode = .scaleAspectFill
            self.imageView.clipsToBounds = true
            self.imageView.layer.cornerRadius = 12.0
            self.imageView.backgroundColor = UIColor.secondarySystemFill
            self.statusLabel.font = ImageBubble.font
            self.statusLabel.numberOfLines = 0
            self.sendButton.setTitle(LuckgramStrings.pick("发送给…", "Send to…"), for: .normal)
            self.saveButton.setTitle(LuckgramStrings.pick("保存", "Save"), for: .normal)
            self.redrawButton.setTitle(LuckgramStrings.pick("重画", "Redraw"), for: .normal)
            for button in [self.sendButton, self.saveButton, self.redrawButton] {
                button.titleLabel?.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
                self.addSubview(button)
            }
            self.sendButton.addTarget(self, action: #selector(self.sendPressed), for: .touchUpInside)
            self.saveButton.addTarget(self, action: #selector(self.savePressed), for: .touchUpInside)
            self.redrawButton.addTarget(self, action: #selector(self.redrawPressed), for: .touchUpInside)
            self.addSubview(self.imageView)
            self.addSubview(self.spinner)
            self.addSubview(self.statusLabel)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private var host: LuckgramAIChatHost? {
            var responder: UIResponder? = self
            while let current = responder {
                if let host = current as? LuckgramAIChatHost {
                    return host
                }
                responder = current.next
            }
            return nil
        }

        @objc private func sendPressed() {
            if let host = self.host, let path = self.message?.data?["path"] {
                LuckgramAIImage.sendTo(host: host, path: path)
            }
        }

        @objc private func savePressed() {
            if let host = self.host, let path = self.message?.data?["path"] {
                LuckgramAIImage.save(host: host, path: path)
            }
        }

        @objc private func redrawPressed() {
            if let host = self.host, let prompt = self.message?.text, !prompt.isEmpty {
                LuckgramAIImage.generate(host: host, prompt: prompt)
            }
        }

        func update(message: LuckgramAIConversation.Message, side: CGFloat) {
            self.message = message
            let state = message.data?["state"] ?? LuckgramAIImage.statePending
            let text = ImageBubble.statusText(message)
            self.statusLabel.text = text
            var y: CGFloat = 0.0
            if state == LuckgramAIImage.stateError {
                self.imageView.isHidden = true
                self.spinner.stopAnimating()
                self.statusLabel.textColor = .systemRed
            } else {
                self.imageView.isHidden = false
                self.imageView.frame = CGRect(x: 0.0, y: 0.0, width: side, height: side)
                self.spinner.center = self.imageView.center
                y = side + 6.0
                self.statusLabel.textColor = state == LuckgramAIImage.stateDone ? .label : .secondaryLabel
                if state == LuckgramAIImage.stateDone, let path = message.data?["path"] {
                    self.spinner.stopAnimating()
                    if self.loadedPath != path {
                        self.loadedPath = path
                        self.imageView.image = nil
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            let image = UIImage(contentsOfFile: path)
                            DispatchQueue.main.async {
                                if let self, self.loadedPath == path {
                                    self.imageView.image = image
                                }
                            }
                        }
                    }
                } else {
                    // spec 23 需求 2: placeholder while drawing
                    self.loadedPath = nil
                    self.imageView.image = nil
                    self.spinner.startAnimating()
                }
            }
            let h = ImageBubble.textHeight(text, width: side)
            self.statusLabel.frame = CGRect(x: 0.0, y: y, width: side, height: h)
            y += h
            let showSend = state == LuckgramAIImage.stateDone
            let showRedraw = state != LuckgramAIImage.statePending
            self.sendButton.isHidden = !showSend
            self.saveButton.isHidden = !showSend
            self.redrawButton.isHidden = !showRedraw
            var x: CGFloat = 0.0
            for button in [self.sendButton, self.saveButton, self.redrawButton] where !button.isHidden {
                button.sizeToFit()
                button.frame = CGRect(x: x, y: y + 4.0, width: button.bounds.width + 8.0, height: 32.0)
                x += button.bounds.width + 8.0
            }
        }
    }
}
