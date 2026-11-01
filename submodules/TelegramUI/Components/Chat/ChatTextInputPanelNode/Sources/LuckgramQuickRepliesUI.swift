// Luckgram: quick reply picker and management screens (feature 02).
// Picker: tap inserts into the input field, long press sends. Manage: add / edit / delete / drag to reorder.

import Foundation
import UIKit
import SwiftSignalKit
import AsyncDisplayKit
import Display
import AccountContext

final class LuckgramQuickRepliesPicker: UITableViewController {
    private let context: AccountContext
    private let strings: LuckgramQuickReplies.Strings
    private let isDark: Bool
    private let insert: (String) -> Void
    private let send: (String) -> Void

    private var items: [String] = []
    private var disposable: Disposable?
    private let cellIdentifier = "template"

    init(context: AccountContext, strings: LuckgramQuickReplies.Strings, isDark: Bool, insert: @escaping (String) -> Void, send: @escaping (String) -> Void) {
        self.context = context
        self.strings = strings
        self.isDark = isDark
        self.insert = insert
        self.send = send
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
    }

    func wrappedInNavigation() -> UINavigationController {
        let navigationController = UINavigationController(rootViewController: self)
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.overrideUserInterfaceStyle = self.isDark ? .dark : .light
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return navigationController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = self.strings.title
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.strings.cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.strings.manage, style: .plain, target: self, action: #selector(self.managePressed))
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: self.cellIdentifier)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:)))
        longPress.minimumPressDuration = 0.4
        self.tableView.addGestureRecognizer(longPress)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.reload()
    }

    private func reload() {
        self.disposable?.dispose()
        self.disposable = (LuckgramQuickReplies.items(context: self.context)
        |> deliverOnMainQueue).startStrict(next: { [weak self] items in
            guard let self else {
                return
            }
            self.items = items
            self.tableView.reloadData()
        })
    }

    private func close(_ completion: (() -> Void)?) {
        let presenting = self.navigationController?.presentingViewController ?? self.presentingViewController
        presenting?.dismiss(animated: true, completion: completion)
    }

    @objc private func cancelPressed() {
        self.close(nil)
    }

    @objc private func managePressed() {
        self.navigationController?.pushViewController(LuckgramQuickRepliesManageController(context: self.context, strings: self.strings), animated: true)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let indexPath = self.tableView.indexPathForRow(at: recognizer.location(in: self.tableView)), indexPath.row < self.items.count else {
            return
        }
        let text = self.items[indexPath.row]
        let send = self.send
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        self.close({
            send(text)
        })
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.items.isEmpty ? 1 : self.items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return self.items.isEmpty ? self.strings.empty : self.strings.hint
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: self.cellIdentifier, for: indexPath)
        var content = UIListContentConfiguration.cell()
        if self.items.isEmpty {
            content.text = self.strings.add
            content.textProperties.color = tableView.tintColor
            content.image = UIImage(systemName: "plus.circle.fill")
        } else {
            content.text = self.items[indexPath.row].replacingOccurrences(of: "\n", with: " ")
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingTail
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if self.items.isEmpty {
            let manage = LuckgramQuickRepliesManageController(context: self.context, strings: self.strings)
            self.navigationController?.pushViewController(manage, animated: true)
            manage.openEditor(index: nil)
            return
        }
        guard indexPath.row < self.items.count else {
            return
        }
        let text = self.items[indexPath.row]
        let insert = self.insert
        self.close({
            insert(text)
        })
    }
}

final class LuckgramQuickRepliesManageController: UITableViewController {
    private let context: AccountContext
    private let strings: LuckgramQuickReplies.Strings
    private var items: [String] = []
    private var disposable: Disposable?
    private let cellIdentifier = "template"
    private var pendingEditor: Int??
    /// Set when hosted as the settings subpage: shows a back button that pops the host.
    var onBack: (() -> Void)?
    private var loaded = false
    private var appeared = false

    init(context: AccountContext, strings: LuckgramQuickReplies.Strings) {
        self.context = context
        self.strings = strings
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = self.strings.title
        if self.onBack != nil {
            let back = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(self.backPressed))
            back.accessibilityLabel = self.strings.back
            self.navigationItem.leftBarButtonItem = back
        }
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: self.cellIdentifier)
        self.tableView.allowsSelectionDuringEditing = true
        self.updateBarButtons()

        self.disposable = (LuckgramQuickReplies.items(context: self.context)
        |> take(1)
        |> deliverOnMainQueue).startStrict(next: { [weak self] items in
            guard let self else {
                return
            }
            self.items = items
            self.loaded = true
            self.tableView.reloadData()
            self.openPendingEditor()
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.appeared = true
        self.openPendingEditor()
    }

    private func openPendingEditor() {
        if let pending = self.pendingEditor, self.loaded, self.appeared {
            self.pendingEditor = nil
            self.openEditor(index: pending)
        }
    }

    private func save() {
        LuckgramQuickReplies.setItems(context: self.context, items: self.items)
    }

    /// "+" to add, "编辑 / 完成" to toggle reordering (swipe left to delete when not editing).
    private func updateBarButtons() {
        let add = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(self.addPressed))
        add.accessibilityLabel = self.strings.add
        let toggle = UIBarButtonItem(title: self.isEditing ? self.strings.done : self.strings.editList, style: self.isEditing ? .done : .plain, target: self, action: #selector(self.toggleEditing))
        self.navigationItem.rightBarButtonItems = [add, toggle]
    }

    @objc private func toggleEditing() {
        self.setEditing(!self.isEditing, animated: true)
        self.updateBarButtons()
    }

    @objc private func backPressed() {
        self.onBack?()
    }

    @objc private func addPressed() {
        self.openEditor(index: nil)
    }

    private func showLimitAlert() {
        let alert = UIAlertController(title: nil, message: self.strings.limitReached, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.strings.ok, style: .default))
        self.present(alert, animated: true)
    }

    func openEditor(index: Int?) {
        guard self.loaded, self.appeared else {
            self.pendingEditor = .some(index)
            return
        }
        if index == nil && self.items.count >= LuckgramQuickReplies.maxCount {
            self.showLimitAlert()
            return
        }
        let initial = index.flatMap { $0 < self.items.count ? self.items[$0] : nil } ?? ""
        let editor = LuckgramQuickReplyEditor(strings: self.strings, title: index == nil ? self.strings.add : self.strings.edit, text: initial, completion: { [weak self] text in
            guard let self, let text = LuckgramQuickReplies.normalize(text) else {
                return
            }
            if let index, index < self.items.count {
                self.items[index] = text
            } else {
                if self.items.count >= LuckgramQuickReplies.maxCount {
                    self.showLimitAlert()
                    return
                }
                self.items.append(text)
            }
            self.save()
            self.tableView.reloadData()
        })
        let navigationController = UINavigationController(rootViewController: editor)
        self.present(navigationController, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.items.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return self.strings.manageInfo
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: self.cellIdentifier, for: indexPath)
        var content = UIListContentConfiguration.cell()
        content.text = self.items[indexPath.row]
        content.textProperties.numberOfLines = 2
        content.textProperties.lineBreakMode = .byTruncatingTail
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        self.openEditor(index: indexPath.row)
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.row < self.items.count else {
            return
        }
        let item = self.items.remove(at: sourceIndexPath.row)
        self.items.insert(item, at: min(destinationIndexPath.row, self.items.count))
        self.save()
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .delete
    }

    override func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        return self.strings.delete
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < self.items.count else {
            return
        }
        self.items.remove(at: indexPath.row)
        self.save()
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}

private final class LuckgramQuickReplyEditor: UIViewController, UITextViewDelegate {
    private let strings: LuckgramQuickReplies.Strings
    private let initialText: String
    private let completion: (String) -> Void
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let counterLabel = UILabel()

    init(strings: LuckgramQuickReplies.Strings, title: String, text: String, completion: @escaping (String) -> Void) {
        self.strings = strings
        self.initialText = text
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemGroupedBackground
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.strings.cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.strings.save, style: .done, target: self, action: #selector(self.savePressed))

        self.textView.font = UIFont.preferredFont(forTextStyle: .body)
        self.textView.adjustsFontForContentSizeCategory = true
        self.textView.backgroundColor = .secondarySystemGroupedBackground
        self.textView.textColor = .label
        self.textView.layer.cornerRadius = 10.0
        self.textView.textContainerInset = UIEdgeInsets(top: 12.0, left: 8.0, bottom: 12.0, right: 8.0)
        self.textView.text = self.initialText
        self.textView.delegate = self
        self.textView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.textView)

        self.placeholderLabel.text = self.strings.placeholder
        self.placeholderLabel.textColor = .placeholderText
        self.placeholderLabel.font = self.textView.font
        self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.placeholderLabel)

        self.counterLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        self.counterLabel.textColor = .secondaryLabel
        self.counterLabel.textAlignment = .right
        self.counterLabel.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.counterLabel)

        let guide = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            self.textView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16.0),
            self.textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16.0),
            self.textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16.0),
            self.textView.heightAnchor.constraint(equalToConstant: 180.0),
            self.placeholderLabel.topAnchor.constraint(equalTo: self.textView.topAnchor, constant: 12.0),
            self.placeholderLabel.leadingAnchor.constraint(equalTo: self.textView.leadingAnchor, constant: 13.0),
            self.counterLabel.topAnchor.constraint(equalTo: self.textView.bottomAnchor, constant: 6.0),
            self.counterLabel.trailingAnchor.constraint(equalTo: self.textView.trailingAnchor)
        ])
        self.updateState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.textView.becomeFirstResponder()
    }

    private func updateState() {
        let count = self.textView.text.count
        self.placeholderLabel.isHidden = count != 0
        self.counterLabel.text = "\(count) / \(LuckgramQuickReplies.maxLength)"
        self.navigationItem.rightBarButtonItem?.isEnabled = LuckgramQuickReplies.normalize(self.textView.text) != nil
    }

    func textViewDidChange(_ textView: UITextView) {
        self.updateState()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let current = textView.text as NSString
        let updated = current.replacingCharacters(in: range, with: text)
        return updated.count <= LuckgramQuickReplies.maxLength
    }

    @objc private func cancelPressed() {
        self.dismiss(animated: true)
    }

    @objc private func savePressed() {
        let text = self.textView.text ?? ""
        let completion = self.completion
        self.dismiss(animated: true, completion: {
            completion(text)
        })
    }
}

/// "Settings -> Luckgram features -> Quick replies" subpage (registered by TelegramUI at startup, since
/// LuckgramUI can't import this module).
public func luckgramQuickRepliesSettingsController(context: AccountContext) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let manage = LuckgramQuickRepliesManageController(context: context, strings: LuckgramQuickReplies.Strings(presentationData.strings))
    let host = LuckgramHostedUIKitController(root: manage, isDark: presentationData.theme.overallDarkAppearance)
    manage.onBack = { [weak host] in
        _ = host?.navigationController?.popViewController(animated: true)
    }
    return host
}

/// Hosts a UIKit screen (with its own UINavigationController bar) inside Telegram's navigation stack.
final class LuckgramHostedUIKitController: ViewController {
    private let child: UINavigationController

    init(root: UIViewController, isDark: Bool) {
        self.child = UINavigationController(rootViewController: root)
        self.child.overrideUserInterfaceStyle = isDark ? .dark : .light
        super.init(navigationBarPresentationData: nil)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.addChild(self.child)
        self.child.view.frame = self.view.bounds
        self.child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(self.child.view)
        self.child.didMove(toParent: self)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.child.view.frame = CGRect(origin: CGPoint(), size: layout.size)
    }
}
