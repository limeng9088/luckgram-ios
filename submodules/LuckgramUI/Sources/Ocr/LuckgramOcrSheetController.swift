import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext

/// specs#106 需求 3: the recognized text, as a native sheet (it also opens over the gallery). The
/// image on top with the text areas highlighted (tap one to select just that block), the text below
/// (keeps line breaks, selectable), and Copy all / Translate (#105's reading language) / Ask AI (into
/// the assistant's input) / Share. Same page as Android `LuckgramOcrSheet`.
public final class LuckgramOcrSheetController: UIViewController {
    /// Recognizes `image` and opens the sheet; a short message if nothing is found.
    /// Recognizes `image` and opens the sheet; a short message if nothing is found. `presentNative`
    /// shows native pages somewhere other than the main window (the attachment preview).
    public static func open(context: AccountContext, image: UIImage, key: String?, presentNative: ((UIViewController) -> Void)? = nil) {
        let present: (UIViewController) -> Void = presentNative ?? { c in
            context.sharedContext.mainWindow?.presentNative(c)
        }
        let _ = (LuckgramOcr.recognize(image: image, key: key)
        |> deliverOnMainQueue).startStandalone(next: { result in
            guard result.hasText else {
                notice(context, LuckgramStrings.pick("图片里没有识别到文字", "No text found in this image"), present: present)
                return
            }
            show(context: context, image: image, result: result, present: present)
        }, error: { _ in
            notice(context, LuckgramStrings.pick("识别失败，请重试", "Couldn't recognize the text. Please try again."), present: present)
        })
    }

    static func show(context: AccountContext, image: UIImage, result: LuckgramOcrResult, present: @escaping (UIViewController) -> Void) {
        let controller = LuckgramOcrSheetController(context: context, image: image, result: result)
        controller.presentNative = present
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        navigation.overrideUserInterfaceStyle = presentationData.theme.overallDarkAppearance ? .dark : .light
        present(navigation)
    }

    static func notice(_ context: AccountContext, _ text: String, present: (UIViewController) -> Void) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        alert.overrideUserInterfaceStyle = presentationData.theme.overallDarkAppearance ? .dark : .light
        present(alert)
    }

    private let context: AccountContext
    private let image: UIImage
    private let result: LuckgramOcrResult
    private let textView = UITextView()
    private let translationLabel = UILabel()
    private let highlights: LuckgramOcrHighlightView
    private var translating = false
    private let disposable = MetaDisposable()
    /// Where this sheet was shown (main window or the attachment preview), to show it again there.
    var presentNative: ((UIViewController) -> Void)?

    init(context: AccountContext, image: UIImage, result: LuckgramOcrResult) {
        self.context = context
        self.image = image
        self.result = result
        self.highlights = LuckgramOcrHighlightView(result: result)
        super.init(nibName: nil, bundle: nil)
        self.title = LuckgramStrings.pick("识别出的文字", "Recognized Text")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable.dispose()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(self.closePressed))

        let scroll = UIScrollView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12.0
        stack.alignment = .fill

        let imageView = UIImageView(image: self.image)
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        let size = self.image.size
        let maxHeight = UIScreen.main.bounds.height * 0.32
        let maxWidth = UIScreen.main.bounds.width - 40.0
        let scale = min(maxWidth / max(1.0, size.width), maxHeight / max(1.0, size.height))
        let imageWrap = UIView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        self.highlights.translatesAutoresizingMaskIntoConstraints = false
        self.highlights.tint = self.view.tintColor
        imageWrap.addSubview(imageView)
        imageWrap.addSubview(self.highlights)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: size.width * scale),
            imageView.heightAnchor.constraint(equalToConstant: size.height * scale),
            imageView.centerXAnchor.constraint(equalTo: imageWrap.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: imageWrap.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageWrap.bottomAnchor),
            self.highlights.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            self.highlights.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            self.highlights.topAnchor.constraint(equalTo: imageView.topAnchor),
            self.highlights.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
        ])
        self.highlights.onSelect = { [weak self] block in
            self?.select(block)
        }
        stack.addArrangedSubview(imageWrap)

        self.textView.text = self.result.text
        self.textView.font = UIFont.systemFont(ofSize: 17.0)
        self.textView.textColor = .label
        self.textView.backgroundColor = .clear
        self.textView.isEditable = false
        self.textView.isSelectable = true
        self.textView.isScrollEnabled = false
        self.textView.textContainerInset = .zero
        self.textView.textContainer.lineFragmentPadding = 0.0
        stack.addArrangedSubview(self.textView)

        self.translationLabel.numberOfLines = 0
        self.translationLabel.font = UIFont.systemFont(ofSize: 17.0)
        self.translationLabel.textColor = .secondaryLabel
        self.translationLabel.isHidden = true
        stack.addArrangedSubview(self.translationLabel)

        let buttons = UIStackView(arrangedSubviews: [
            self.button("doc.on.doc", LuckgramStrings.pick("复制全部", "Copy All"), #selector(self.copyPressed)),
            self.button("character.bubble", LuckgramStrings.pick("翻译", "Translate"), #selector(self.translatePressed)),
            self.button("sparkles", LuckgramStrings.pick("问 AI", "Ask AI"), #selector(self.askPressed)),
            self.button("square.and.arrow.up", LuckgramStrings.pick("分享", "Share"), #selector(self.sharePressed))
        ])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually

        for v in [scroll, buttons] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(v)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let guide = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12.0),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12.0),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20.0),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20.0),
            buttons.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 8.0),
            buttons.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -8.0),
            buttons.heightAnchor.constraint(equalToConstant: 64.0),
            buttons.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -4.0)
        ])
    }

    private func button(_ symbol: String, _ title: String, _ action: Selector) -> UIView {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        b.accessibilityLabel = title
        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(ofSize: 12.0)
        label.textColor = self.view.tintColor
        label.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [b, label])
        column.axis = .vertical
        column.spacing = 2.0
        let tap = UITapGestureRecognizer(target: self, action: action)
        column.addGestureRecognizer(tap)
        return column
    }

    /// The selected text, or everything when nothing is selected.
    private var currentText: String {
        let range = self.textView.selectedRange
        if range.length > 0, let text = self.textView.text, let r = Range(range, in: text) {
            return String(text[r])
        }
        return self.result.text
    }

    private func select(_ block: LuckgramOcrResult.Block?) {
        guard let block, let text = self.textView.text, let r = text.range(of: block.text) else {
            return
        }
        self.textView.becomeFirstResponder()
        self.textView.selectedRange = NSRange(r, in: text)
    }

    @objc private func closePressed() {
        self.dismiss(animated: true)
    }

    @objc private func copyPressed() {
        UIPasteboard.general.string = self.result.text
        self.translationLabel.isHidden = false
        if self.translationLabel.text == nil || self.translationLabel.text?.isEmpty == true {
            self.translationLabel.text = LuckgramStrings.pick("已复制", "Copied")
            Queue.mainQueue().after(1.5, { [weak self] in
                if self?.translationLabel.text == LuckgramStrings.pick("已复制", "Copied") {
                    self?.translationLabel.text = nil
                    self?.translationLabel.isHidden = true
                }
            })
        }
    }

    @objc private func translatePressed() {
        if self.translating {
            return
        }
        let context = self.context
        // The AI consent alert is a Telegram one: it would open behind this native sheet, so step
        // out of the way while it's asked (same as the AI assistant).
        if !LuckgramAI.shared.hasConsent, let navigation = self.navigationController {
            navigation.dismiss(animated: true, completion: {
                let _ = (LuckgramAI.shared.requestConsent(context: context, present: { c in
                    context.sharedContext.mainWindow?.present(c, on: .root)
                })
                |> deliverOnMainQueue).startStandalone(next: { [weak self] granted in
                    if let present = self?.presentNative {
                        present(navigation)
                    } else {
                        context.sharedContext.mainWindow?.presentNative(navigation)
                    }
                    if granted {
                        self?.translatePressed()
                    }
                })
            })
            return
        }
        let to = LuckgramTranslateInController.targetLanguage ?? String((Locale.preferredLanguages.first ?? "en").prefix(2))
        self.translating = true
        self.translationLabel.isHidden = false
        self.translationLabel.text = LuckgramStrings.pick("正在翻译…", "Translating…")
        self.disposable.set((LuckgramAI.shared.translate(context: context, present: nil, text: self.currentText, toLang: to, fromLang: self.result.language)
        |> deliverOnMainQueue).startStrict(next: { [weak self] translation in
            self?.translating = false
            self?.translationLabel.text = translation.text
        }, error: { [weak self] error in
            self?.translating = false
            self?.translationLabel.text = error.localizedMessage
        }))
    }

    @objc private func askPressed() {
        let context = self.context
        let prompt = LuckgramStrings.pick("图片里的文字：\n", "Text from an image:\n") + self.currentText + "\n\n"
        let presenting = self.navigationController ?? self
        presenting.dismiss(animated: true, completion: {
            LuckgramAIChatController.openNew(context: context, prefill: prompt)
        })
    }

    @objc private func sharePressed() {
        let activity = UIActivityViewController(activityItems: [self.currentText], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = self.view
        activity.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY - 40.0, width: 1.0, height: 1.0)
        self.present(activity, animated: true)
    }
}

/// Translucent boxes over the recognized text areas; tapping one selects that block.
final class LuckgramOcrHighlightView: UIView {
    private let result: LuckgramOcrResult
    var tint: UIColor = .systemBlue
    var onSelect: ((LuckgramOcrResult.Block?) -> Void)?
    private var selectedIndex: Int?

    init(result: LuckgramOcrResult) {
        self.result = result
        super.init(frame: .zero)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        guard self.bounds.width > 0.0, self.bounds.height > 0.0 else {
            return
        }
        let block = self.result.block(atX: Double(p.x / self.bounds.width), y: Double(p.y / self.bounds.height))
        self.selectedIndex = block.flatMap { b in self.result.blocks.firstIndex(where: { $0 == b }) }
        self.setNeedsDisplay()
        self.onSelect?(block)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        let w = self.bounds.width, h = self.bounds.height
        for (i, b) in self.result.blocks.enumerated() {
            let r = CGRect(x: CGFloat(b.box.x) * w, y: CGFloat(b.box.y) * h, width: CGFloat(b.box.width) * w, height: CGFloat(b.box.height) * h)
            let path = UIBezierPath(roundedRect: r, cornerRadius: 3.0)
            ctx.setFillColor(self.tint.withAlphaComponent(i == self.selectedIndex ? 0.42 : 0.22).cgColor)
            path.fill()
            if i == self.selectedIndex {
                ctx.setStrokeColor(self.tint.cgColor)
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }
}
