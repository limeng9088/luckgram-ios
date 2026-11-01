import Foundation
import UIKit
import SwiftSignalKit
import TelegramPresentationData
import AccountContext

/// spec 18 需求 6: list of stored AI conversations; tap to open, swipe or long-press to delete.
final class LuckgramAIHistoryController: UITableViewController {
    private let context: AccountContext
    private let theme: PresentationTheme
    private let onPick: (LuckgramAIConversation) -> Void
    private var items: [LuckgramAIConversation] = []
    private var disposable: Disposable?
    private let emptyLabel = UILabel()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(context: AccountContext, theme: PresentationTheme, onPick: @escaping (LuckgramAIConversation) -> Void) {
        self.context = context
        self.theme = theme
        self.onPick = onPick
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
    }

    private var store: LuckgramAIStore {
        return LuckgramAIStore.shared(context: self.context)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = LuckgramStrings.pick("历史对话", "Chat history")
        self.tableView.backgroundColor = self.theme.list.plainBackgroundColor
        self.tableView.separatorColor = self.theme.list.itemPlainSeparatorColor
        self.emptyLabel.text = LuckgramStrings.pick("还没有对话", "No chats yet")
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.textColor = self.theme.list.itemSecondaryTextColor
        self.tableView.backgroundView = self.emptyLabel
        self.reload()
        self.disposable = (self.store.changes |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
            self?.reload()
        })
    }

    private func reload() {
        self.items = self.store.list()
        self.emptyLabel.isHidden = !self.items.isEmpty
        self.tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "row")
        let item = self.items[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = (item.title?.isEmpty == false ? item.title : nil) ?? LuckgramStrings.pick("新对话", "New chat")
        config.textProperties.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
        config.textProperties.color = self.theme.list.itemPrimaryTextColor
        config.textProperties.numberOfLines = 1
        let last = item.messages.last(where: { !($0.text ?? "").isEmpty })?.text?.replacingOccurrences(of: "\n", with: " ") ?? ""
        let date = self.dateFormatter.string(from: Date(timeIntervalSince1970: item.updatedAt))
        config.secondaryText = date + " · " + last
        config.secondaryTextProperties.color = self.theme.list.itemSecondaryTextColor
        config.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = config
        cell.backgroundColor = self.theme.list.plainBackgroundColor
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = self.items[indexPath.row]
        self.navigationController?.popViewController(animated: true)
        self.onPick(item)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = self.items[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: LuckgramStrings.pick("删除", "Delete")) { [weak self] _, _, done in
            self?.confirmDelete(item, done: done)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let item = self.items[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { [weak self] _ in
            return UIMenu(children: [UIAction(title: LuckgramStrings.pick("删除对话", "Delete chat"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.confirmDelete(item, done: { _ in })
            }])
        })
    }

    private func confirmDelete(_ item: LuckgramAIConversation, done: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: LuckgramStrings.pick("删除对话", "Delete chat"), message: LuckgramStrings.pick("删除后无法恢复。", "This can't be undone."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel) { _ in done(false) })
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("删除", "Delete"), style: .destructive) { [weak self] _ in
            self?.store.delete(item.id)
            done(true)
        })
        self.present(alert, animated: true)
    }
}
