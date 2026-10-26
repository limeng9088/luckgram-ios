// Luckgram: target-language picker for "translate before sending".
// Frequently used languages first, then all languages; searchable by name in any language.

import Foundation
import UIKit

final class LuckgramTranslateOutLanguagePicker: UITableViewController, UISearchResultsUpdating {
    private struct Item {
        let code: String
        let name: String
        let ownName: String?
        let query: String
    }

    private let strings: LuckgramTranslateOut.Strings
    private let selected: String?
    private let isDark: Bool
    private let completion: (String) -> Void

    private var commonItems: [Item] = []
    private var allItems: [Item] = []
    private var filteredItems: [Item]?

    private let searchController = UISearchController(searchResultsController: nil)
    private let cellIdentifier = "language"

    init(strings: LuckgramTranslateOut.Strings, selected: String?, recent: [String], isDark: Bool, completion: @escaping (String) -> Void) {
        self.strings = strings
        self.selected = selected
        self.isDark = isDark
        self.completion = completion

        super.init(style: .insetGrouped)

        var commonCodes: [String] = []
        for code in ([selected].compactMap { $0 } + recent + LuckgramTranslateOut.commonLanguages) {
            if !commonCodes.contains(code) {
                commonCodes.append(code)
            }
        }
        self.commonItems = commonCodes.map { self.item($0) }
        self.allItems = LuckgramTranslateOut.allLanguages.map { self.item($0) }.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func item(_ code: String) -> Item {
        let name = self.strings.languageName(code)
        var ownName = LuckgramTranslateOut.ownLanguageName(code)
        if let value = ownName, value.caseInsensitiveCompare(name) == .orderedSame {
            ownName = nil
        }
        return Item(code: code, name: name, ownName: ownName, query: "\(name) \(ownName ?? "") \(code)".lowercased())
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

        self.title = self.strings.pickerTitle
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.strings.cancel, style: .plain, target: self, action: #selector(self.cancelPressed))

        self.searchController.searchResultsUpdater = self
        self.searchController.obscuresBackgroundDuringPresentation = false
        self.searchController.searchBar.placeholder = self.strings.search
        self.navigationItem.searchController = self.searchController
        self.navigationItem.hidesSearchBarWhenScrolling = false
        self.definesPresentationContext = true

        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: self.cellIdentifier)
    }

    @objc private func cancelPressed() {
        let presenting = self.navigationController?.presentingViewController ?? self.presentingViewController
        presenting?.dismiss(animated: true, completion: nil)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            self.filteredItems = nil
        } else {
            self.filteredItems = self.allItems.filter { $0.query.contains(query) }
        }
        self.tableView.reloadData()
    }

    private func items(section: Int) -> [Item] {
        if let filteredItems = self.filteredItems {
            return filteredItems
        }
        return section == 0 ? self.commonItems : self.allItems
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return self.filteredItems == nil ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.items(section: section).count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if self.filteredItems != nil {
            return nil
        }
        return section == 0 ? self.strings.common : self.strings.all
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let filteredItems = self.filteredItems, filteredItems.isEmpty {
            return self.strings.noResults
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: self.cellIdentifier, for: indexPath)
        let item = self.items(section: indexPath.section)[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.name
        content.secondaryText = item.ownName
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = item.code == self.selected ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let code = self.items(section: indexPath.section)[indexPath.row].code
        let completion = self.completion
        let presenting = self.navigationController?.presentingViewController ?? self.presentingViewController
        presenting?.dismiss(animated: true, completion: {
            completion(code)
        })
    }
}
