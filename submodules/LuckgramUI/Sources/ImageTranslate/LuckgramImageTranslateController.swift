import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext

/// specs#108: the translated image. Translations are drawn over the original at each text block
/// (needs 3); the header 「日本語 → 中文 ▾」 changes the language (needs 2); bottom: original /
/// translation, copy, save, share, and — from the gallery preview — send the translated image
/// (needs 4). Long-press a block for its original and translation. Same layout and texts as Android
/// `ImageTranslateActivity`. Presented full screen over the app.
public final class LuckgramImageTranslateController: UIViewController, UIScrollViewDelegate {
    private let context: AccountContext
    private let original: UIImage
    private var blocks: [LuckgramImageTranslateRenderer.Block]
    private let imageLanguage: String?
    private let peerId: Int64?
    private let sendTranslated: ((UIImage) -> Void)?

    private var translated: UIImage?
    private var showingTranslation = true
    private var toLang: String
    private var fromLang: String?
    private let disposable = MetaDisposable()
    private var generation = 0

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let headerButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let statusLabel = PaddedLabel()
    private let bar = UIStackView()
    private var toggleButton: UIButton?

    /// - Parameters:
    ///   - imageLanguage: the image's language from OCR (BCP-47) or nil.
    ///   - sendTranslated: non-nil in the gallery preview.
    public init(context: AccountContext, image: UIImage, blocks: [LuckgramImageTranslateRenderer.Block], imageLanguage: String?, peerId: Int64?, sendTranslated: ((UIImage) -> Void)?) {
        self.context = context
        self.original = image
        self.blocks = blocks
        self.imageLanguage = imageLanguage
        self.peerId = peerId
        self.sendTranslated = sendTranslated
        self.toLang = LuckgramImageTranslateSettings.targetLanguage(accountPeerId: context.account.peerId, peerId: peerId)
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable.dispose()
    }

    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black

        self.scrollView.delegate = self
        self.scrollView.minimumZoomScale = 1.0
        self.scrollView.maximumZoomScale = 6.0
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.view.addSubview(self.scrollView)
        self.imageView.contentMode = .scaleAspectFit
        self.imageView.image = self.original
        self.imageView.isUserInteractionEnabled = true
        self.scrollView.addSubview(self.imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(self.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        self.scrollView.addGestureRecognizer(doubleTap)
        self.imageView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:))))

        self.closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        self.closeButton.tintColor = .white
        self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        self.view.addSubview(self.closeButton)

        self.headerButton.setTitleColor(.white, for: .normal)
        self.headerButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17.0)
        self.headerButton.titleLabel?.lineBreakMode = .byTruncatingTail
        self.headerButton.addTarget(self, action: #selector(self.changeLanguage), for: .touchUpInside)
        self.view.addSubview(self.headerButton)

        self.statusLabel.textColor = .white
        self.statusLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.statusLabel.backgroundColor = UIColor(white: 0.0, alpha: 0.67)
        self.statusLabel.layer.cornerRadius = 16.0
        self.statusLabel.clipsToBounds = true
        self.statusLabel.isHidden = true
        self.view.addSubview(self.statusLabel)

        self.bar.axis = .horizontal
        self.bar.distribution = .fillProportionally
        self.bar.backgroundColor = .black
        self.toggleButton = self.barButton(LuckgramImageTranslateStrings.original, #selector(self.togglePressed))
        self.bar.addArrangedSubview(self.toggleButton!)
        self.bar.addArrangedSubview(self.barButton(LuckgramImageTranslateStrings.copy, #selector(self.copyPressed)))
        if self.sendTranslated != nil {
            self.bar.addArrangedSubview(self.barButton(LuckgramImageTranslateStrings.sendTranslated, #selector(self.sendPressed)))
        } else {
            self.bar.addArrangedSubview(self.barButton(LuckgramImageTranslateStrings.save, #selector(self.savePressed)))
            self.bar.addArrangedSubview(self.barButton(LuckgramImageTranslateStrings.share, #selector(self.sharePressed)))
        }
        self.view.addSubview(self.bar)

        self.updateHeader()
        self.translate()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !LuckgramImageTranslateSettings.hasChosen(peerId: self.peerId) && !self.askedOnce {
            // needs 2: first use asks; until then images follow the reading translation language
            self.askedOnce = true
            self.changeLanguage()
        }
    }
    private var askedOnce = false

    private func barButton(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14.0)
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = self.view.safeAreaInsets
        let size = self.view.bounds.size
        let top = safe.top
        self.closeButton.frame = CGRect(x: 8.0, y: top, width: 44.0, height: 44.0)
        self.headerButton.frame = CGRect(x: 56.0, y: top, width: size.width - 112.0, height: 44.0)
        let barHeight: CGFloat = 56.0
        self.bar.frame = CGRect(x: 0.0, y: size.height - safe.bottom - barHeight, width: size.width, height: barHeight)
        let scrollFrame = CGRect(x: 0.0, y: top + 44.0, width: size.width, height: self.bar.frame.minY - top - 44.0)
        if self.scrollView.frame != scrollFrame {
            self.scrollView.zoomScale = 1.0
            self.scrollView.frame = scrollFrame
            self.imageView.frame = CGRect(origin: .zero, size: scrollFrame.size)
            self.scrollView.contentSize = scrollFrame.size
        }
        let statusSize = self.statusLabel.sizeThatFits(CGSize(width: size.width - 40.0, height: 40.0))
        self.statusLabel.frame = CGRect(x: floor((size.width - statusSize.width) / 2.0), y: top + 56.0, width: statusSize.width, height: statusSize.height)
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return self.imageView
    }

    // MARK: Header / status

    private func updateHeader() {
        let from = self.fromLang ?? self.imageLanguage
        let title = LuckgramImageTranslateLogic.header(fromName: LuckgramImageTranslateSettings.languageName(from), toName: LuckgramImageTranslateSettings.languageName(self.toLang) ?? self.toLang)
        self.headerButton.setTitle(title, for: .normal)
    }

    private func status(_ text: String?) {
        self.statusLabel.text = text
        self.statusLabel.isHidden = text == nil
        self.view.setNeedsLayout()
    }

    // MARK: Translate

    private func translate() {
        self.generation += 1
        let gen = self.generation
        var texts: [String?] = []
        for i in self.blocks.indices {
            self.blocks[i].translation = nil
            let go = LuckgramImageTranslateLogic.shouldTranslate(text: self.blocks[i].original, blockLanguage: nil, imageLanguage: self.imageLanguage, targetLanguage: self.toLang)
            texts.append(go ? self.blocks[i].original : nil)
        }
        if texts.allSatisfy({ $0 == nil }) {
            self.status(LuckgramImageTranslateStrings.noText)
            self.show(translated: self.original)
            return
        }
        self.status(LuckgramImageTranslateStrings.translating)
        self.disposable.set(LuckgramImageTranslator.translate(context: self.context, texts: texts, toLang: self.toLang).start(next: { [weak self] translations, from in
            guard let self, gen == self.generation else {
                return
            }
            for i in self.blocks.indices where i < translations.count {
                self.blocks[i].translation = translations[i]
            }
            if let from {
                self.fromLang = from
            }
            self.updateHeader()
            let blocks = self.blocks
            let original = self.original
            Queue.concurrentDefaultQueue().async {
                let rendered = LuckgramImageTranslateRenderer.render(image: original, blocks: blocks)
                Queue.mainQueue().async { [weak self] in
                    guard let self, gen == self.generation else {
                        return
                    }
                    self.status(nil)
                    self.show(translated: rendered)
                }
            }
        }, error: { [weak self] error in
            guard let self, gen == self.generation else {
                return
            }
            self.status(nil)
            self.toast(LuckgramImageTranslator.failureMessage(error))
        }))
    }

    private func show(translated: UIImage) {
        self.translated = translated
        self.showingTranslation = true
        self.imageView.image = translated
        self.toggleButton?.setTitle(LuckgramImageTranslateStrings.original, for: .normal)
    }

    @objc private func togglePressed() {
        guard let translated = self.translated else {
            return
        }
        self.showingTranslation.toggle()
        self.imageView.image = self.showingTranslation ? translated : self.original
        self.toggleButton?.setTitle(self.showingTranslation ? LuckgramImageTranslateStrings.original : LuckgramImageTranslateStrings.translated, for: .normal)
    }

    /// needs 2: pick a language → (in a chat) only this chat / as default → translate again.
    @objc private func changeLanguage() {
        let shown = LuckgramImageTranslateSettings.pickLanguage(selected: self.toLang, completion: { [weak self] code in
            guard let self else {
                return
            }
            guard self.peerId != nil else {
                self.apply(code, onlyThisChat: false)
                return
            }
            // #105's 「仅本聊天 / 设为默认」 prompt (it only asks; the image language is stored here)
            let name = LuckgramImageTranslateSettings.languageName(code) ?? code
            LuckgramTranslateInController.askScope(context: self.context, languageName: name, completion: { [weak self] chatOnly in
                self?.apply(code, onlyThisChat: chatOnly)
            })
        })
        if !shown {
            self.toast(LuckgramStrings.pick("暂时无法打开语言列表", "The language list isn't available right now"))
        }
    }

    private func apply(_ code: String, onlyThisChat: Bool) {
        LuckgramImageTranslateSettings.setLanguage(peerId: self.peerId, lang: code, onlyThisChat: onlyThisChat)
        self.toLang = code
        self.fromLang = nil
        self.updateHeader()
        self.translate()
    }

    // MARK: Long press

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let image = self.imageView.image else {
            return
        }
        // aspect-fit rect of the image inside the image view
        let bounds = self.imageView.bounds
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * fit, h = image.size.height * fit
        let rect = CGRect(x: (bounds.width - w) / 2.0, y: (bounds.height - h) / 2.0, width: w, height: h)
        let p = recognizer.location(in: self.imageView)
        guard rect.contains(p) else {
            return
        }
        let nx = Double((p.x - rect.minX) / rect.width), ny = Double((p.y - rect.minY) / rect.height)
        guard let index = LuckgramImageTranslateRenderer.hitTest(blocks: self.blocks, x: nx, y: ny) else {
            return
        }
        let block = self.blocks[index]
        var message = LuckgramImageTranslateStrings.originalLabel + "\n" + block.original
        if let t = block.translation, !t.isEmpty {
            message += "\n\n" + LuckgramImageTranslateStrings.translationLabel + "\n" + t
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("复制", "Copy"), style: .default, handler: { [weak self] _ in
            UIPasteboard.general.string = (block.translation?.isEmpty == false) ? block.translation : block.original
            self?.toast(LuckgramImageTranslateStrings.copied)
        }))
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("关闭", "Close"), style: .cancel))
        self.present(alert, animated: true)
    }

    @objc private func doubleTapped() {
        self.scrollView.setZoomScale(self.scrollView.zoomScale > 1.0 ? 1.0 : 2.5, animated: true)
    }

    // MARK: Actions

    @objc private func closePressed() {
        self.disposable.set(nil)
        self.dismiss(animated: true)
    }

    @objc private func copyPressed() {
        UIPasteboard.general.string = LuckgramImageTranslateLogic.copyText(originals: self.blocks.map(\.original), translations: self.blocks.map(\.translation))
        self.toast(LuckgramImageTranslateStrings.copied)
    }

    @objc private func savePressed() {
        guard let translated = self.translated else {
            return
        }
        UIImageWriteToSavedPhotosAlbum(translated, self, #selector(self.image(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if error == nil {
            self.toast(LuckgramImageTranslateStrings.saved)
        } else {
            self.toast(LuckgramStrings.pick("保存失败，请在系统设置里允许 Luckgram 访问照片", "Couldn't save. Allow Luckgram to add photos in Settings"))
        }
    }

    @objc private func sharePressed() {
        guard let translated = self.translated else {
            return
        }
        let controller = UIActivityViewController(activityItems: [translated], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = self.bar
        controller.popoverPresentationController?.sourceRect = self.bar.bounds
        self.present(controller, animated: true)
    }

    @objc private func sendPressed() {
        guard let translated = self.translated, let send = self.sendTranslated else {
            return
        }
        self.dismiss(animated: true, completion: {
            send(translated)
        })
    }

    private func toast(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        self.present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak alert] in
            alert?.dismiss(animated: true)
        }
    }
}

/// A label with padding (the "Translating…" pill).
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 7.0, left: 14.0, bottom: 7.0, right: 14.0)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: self.insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(CGSize(width: size.width - self.insets.left - self.insets.right, height: size.height))
        return CGSize(width: s.width + self.insets.left + self.insets.right, height: s.height + self.insets.top + self.insets.bottom)
    }
}
