import Foundation
import UIKit
import SwiftSignalKit
import Display
import AccountContext

/// specs#88 (30): the AI agent market on iOS. Talks to S13 (`/v1/agents…`), keeps the per-account
/// cache and the agents the user has chatted with ("我的"), and opens a market agent as an AI
/// assistant conversation with `task=agent` + `agent_id` (the system instruction stays on the server).
public enum LuckgramAgentMarket {
    private static let cacheKey = "ai_agent_market_cache"
    private static let usedKey = "ai_agent_market_used"

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(LuckgramFeatures.aiAgentMarket) && LuckgramAgents.isEnabled
    }

    /// spec 30 平台入口提示: the one registration line, called from the AI assistant's registry.
    /// Replaces 22's "智能体" entry with the same page plus a "市场" tab while the market is on.
    static func register() {
        LuckgramAIRegistry.registerHeaderEntry(.init(id: "agents", title: ("智能体", "Agents"), icon: "person.2.crop.square.stack", isVisible: { LuckgramAgents.isEnabled }, action: { host in
            let controller: UIViewController
            if LuckgramAgentMarket.isEnabled {
                controller = LuckgramAgentsHubController(context: host.context, host: host)
            } else {
                controller = LuckgramAgentsController(context: host.context, host: host)
            }
            host.viewController.navigationController?.pushViewController(controller, animated: true)
        }))
    }

    // MARK: - Local data (per account, removed on logout)

    static func cache(accountId: Int64) -> LuckgramAgentMarketLogic.Cache {
        return .decode(LuckgramSettings.shared.string(self.cacheKey, forAccount: accountId, default: nil))
    }

    static func updateCache(accountId: Int64, _ f: (inout LuckgramAgentMarketLogic.Cache) -> Void) {
        var cache = self.cache(accountId: accountId)
        f(&cache)
        LuckgramSettings.shared.setString(self.cacheKey, cache.encoded(), forAccount: accountId)
    }

    public static func used(accountId: Int64) -> [LuckgramAgentMarketLogic.Agent] {
        return LuckgramAgentMarketLogic.decodeUsed(LuckgramSettings.shared.string(self.usedKey, forAccount: accountId, default: nil))
    }

    private static func saveUsed(_ used: [LuckgramAgentMarketLogic.Agent], accountId: Int64) {
        LuckgramSettings.shared.setString(self.usedKey, LuckgramAgentMarketLogic.encodeUsed(used), forAccount: accountId)
    }

    public static func findUsed(_ id: String, accountId: Int64) -> LuckgramAgentMarketLogic.Agent? {
        return self.used(accountId: accountId).first(where: { $0.id == id })
    }

    /// Fresh data from the server for an agent already in "我的" (name, avatar …).
    static func refreshUsed(_ agent: LuckgramAgentMarketLogic.Agent, accountId: Int64) {
        let used = self.used(accountId: accountId)
        if used.contains(where: { $0.id == agent.id }) {
            self.saveUsed(LuckgramAgentMarketLogic.refreshUsed(used, agent), accountId: accountId)
        }
    }

    /// Removes a market agent from "我的": its conversation and chat list entry too.
    public static func remove(_ id: String, context: AccountContext) {
        let accountId = context.account.id.int64
        self.saveUsed(LuckgramAgentMarketLogic.removeUsed(self.used(accountId: accountId), id: id), accountId: accountId)
        LuckgramAgents.setPinned(LuckgramAgents.marketAgentId(id), false, accountId: accountId)
        let store = LuckgramAIStore.shared(context: context)
        let key = LuckgramAgentMarketLogic.conversationKey(id)
        for conversation in store.list() where conversation.key == key {
            store.delete(conversation.id)
        }
    }

    // MARK: - Server (S13)

    static func loadCategories(accountId: Int64) -> Signal<[LuckgramAgentMarketLogic.Category], LuckgramAIError> {
        return LuckgramAI.shared.requestJSON(method: "GET", path: LuckgramAgentMarketLogic.categoriesPath)
        |> map { object -> [LuckgramAgentMarketLogic.Category] in
            let categories = LuckgramAgentMarketLogic.parseCategories(object)
            self.updateCache(accountId: accountId) { $0.categories = categories }
            return categories
        }
    }

    /// One page of the list; the first page without a search is cached.
    static func loadPage(accountId: Int64, category: String, query: String, cursor: String?) -> Signal<LuckgramAgentMarketLogic.Page, LuckgramAIError> {
        let path = LuckgramAgentMarketLogic.listPath(category: category, query: query, cursor: cursor, limit: LuckgramAgentMarketLogic.pageSize)
        let cacheable = (cursor ?? "").isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return LuckgramAI.shared.requestJSON(method: "GET", path: path)
        |> map { object -> LuckgramAgentMarketLogic.Page in
            let page = LuckgramAgentMarketLogic.parsePage(object)
            if cacheable {
                self.updateCache(accountId: accountId) { $0.putFirstPage(category: category, page) }
            }
            for agent in page.items {
                self.refreshUsed(agent, accountId: accountId)
            }
            return page
        }
    }

    static func loadDetail(accountId: Int64, id: String) -> Signal<LuckgramAgentMarketLogic.Agent, LuckgramAIError> {
        return LuckgramAI.shared.requestJSON(method: "GET", path: LuckgramAgentMarketLogic.detailPath(id))
        |> mapToSignal { object -> Signal<LuckgramAgentMarketLogic.Agent, LuckgramAIError> in
            guard let agent = LuckgramAgentMarketLogic.parseAgent(object["agent"]) else {
                return .fail(LuckgramAIError(code: LuckgramAIError.agentUnavailable, httpStatus: 404))
            }
            self.updateCache(accountId: accountId) { $0.putDetail(agent) }
            self.refreshUsed(agent, accountId: accountId)
            return .single(agent)
        }
    }

    // MARK: - Chat (spec 30 需求 4, 5)

    /// "开始聊天": Pro-only agents ask a free user to upgrade first (the server checks too, S13);
    /// otherwise opens (or continues) the agent's conversation and lists it under "我的".
    /// Without a `presenter` (e.g. from the chat list) the server's `not_pro` shows in the chat.
    static func open(_ agent: LuckgramAgentMarketLogic.Agent, context: AccountContext, from presenter: UIViewController?, host: LuckgramAIChatHost?) {
        if let presenter, LuckgramAgentMarketLogic.needsUpgrade(agent, isPro: LuckgramPro.shared.isPro) {
            self.showUpgrade(agent, context: context, presenter: presenter)
            return
        }
        let accountId = context.account.id.int64
        self.saveUsed(LuckgramAgentMarketLogic.markUsed(self.used(accountId: accountId), agent), accountId: accountId)
        let title = agent.name.pick(chinese: LuckgramStrings.isChinese)
        let store = LuckgramAIStore.shared(context: context)
        let conversation = store.findOrCreate(key: LuckgramAgentMarketLogic.conversationKey(agent.id), task: .agent, systemPrompt: nil, title: title)
        conversation.systemPrompt = nil // never on the client: the server injects it by agent_id
        conversation.requestParams = LuckgramAgentMarketLogic.chatParams(agentId: agent.id)
        conversation.title = title
        store.save(conversation)
        LuckgramAIChatController.open(context: context, conversationId: conversation.id, from: host)
    }

    /// spec 30 需求 5: the Pro upgrade prompt (spec 29); "升级 Pro" opens the Luckgram Pro page.
    static func showUpgrade(_ agent: LuckgramAgentMarketLogic.Agent, context: AccountContext, presenter: UIViewController) {
        let name = agent.name.pick(chinese: LuckgramStrings.isChinese)
        let alert = UIAlertController(title: LuckgramStrings.pick("Pro 专享智能体", "Pro agent"), message: LuckgramStrings.pick("「\(name)」是 Luckgram Pro 专享智能体。升级到 Pro 后即可开始聊天。", "\"\(name)\" is available with Luckgram Pro. Upgrade to Pro to start chatting."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("升级 Pro", "Upgrade to Pro"), style: .default) { _ in
            // The assistant is a native modal: close it, then push the Pro page on the app's navigation.
            let push: () -> Void = {
                (context.sharedContext.mainWindow?.viewController as? NavigationController)?.pushViewController(luckgramProController(context: context))
            }
            if let modal = presenter.navigationController, modal.presentingViewController != nil {
                modal.dismiss(animated: true, completion: push)
            } else {
                push()
            }
        })
        presenter.present(alert, animated: true)
    }

    /// Round avatar: the agent's color with its emoji (or initial).
    static func avatarImage(_ agent: LuckgramAgentMarketLogic.Agent, size: CGFloat) -> UIImage {
        return LuckgramAgents.avatarImage(LuckgramAgents.fromMarket(agent), size: size)
    }

    static func proBadge() -> UILabel {
        let label = PaddedLabel()
        label.text = "Pro"
        label.font = UIFont.systemFont(ofSize: 11.0, weight: .bold)
        label.textColor = .white
        label.backgroundColor = UIColor(red: 0.48, green: 0.36, blue: 1.0, alpha: 1.0)
        label.layer.cornerRadius = 6.0
        label.layer.masksToBounds = true
        label.sizeToFit()
        return label
    }

    final class PaddedLabel: UILabel {
        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: UIEdgeInsets(top: 1.0, left: 6.0, bottom: 1.0, right: 6.0)))
        }

        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width + 12.0, height: size.height + 2.0)
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            return self.intrinsicContentSize
        }
    }
}

// MARK: - "我的" | "市场" (spec 30 需求 1)

final class LuckgramAgentsHubController: UIViewController {
    private let context: AccountContext
    private weak var host: LuckgramAIChatHost?
    private let mine: LuckgramAgentsController
    private var market: LuckgramAgentMarketController?
    private let segment = UISegmentedControl(items: [LuckgramStrings.pick("我的", "Mine"), LuckgramStrings.pick("市场", "Market")])

    init(context: AccountContext, host: LuckgramAIChatHost?) {
        self.context = context
        self.host = host
        self.mine = LuckgramAgentsController(context: context, host: host)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemGroupedBackground
        self.segment.selectedSegmentIndex = 0
        self.segment.addTarget(self, action: #selector(self.segmentChanged), for: .valueChanged)
        self.navigationItem.titleView = self.segment
        self.display(self.mine)
    }

    private func display(_ child: UIViewController) {
        for current in self.children where current !== child {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        if child.parent !== self {
            self.addChild(child)
            child.view.frame = self.view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.view.addSubview(child.view)
            child.didMove(toParent: self)
        }
    }

    @objc private func segmentChanged() {
        if self.segment.selectedSegmentIndex == 1 {
            let market = self.market ?? LuckgramAgentMarketController(context: self.context, host: self.host)
            self.market = market
            self.display(market)
        } else {
            self.display(self.mine)
        }
    }
}

// MARK: - Market tab (spec 30 需求 2, 7)

final class LuckgramAgentMarketController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let context: AccountContext
    private weak var host: LuckgramAIChatHost?
    private let searchBar = UISearchBar()
    private let tabsScroll = UIScrollView()
    private let tabsStack = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let footer = UILabel()

    private var categories: [LuckgramAgentMarketLogic.Category] = []
    private var category = ""
    private var query = ""
    private var items: [LuckgramAgentMarketLogic.Agent] = []
    private var nextCursor: String?
    private var loading = false
    private var offline = false
    private var error: LuckgramAIError?
    private let pageDisposable = MetaDisposable()
    private let categoriesDisposable = MetaDisposable()
    private var generation = 0
    private var searchTimer: Timer?

    private var accountId: Int64 {
        return self.context.account.id.int64
    }

    init(context: AccountContext, host: LuckgramAIChatHost?) {
        self.context = context
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.pageDisposable.dispose()
        self.categoriesDisposable.dispose()
        self.searchTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground

        self.searchBar.placeholder = LuckgramStrings.pick("搜索智能体", "Search agents")
        self.searchBar.searchBarStyle = .minimal
        self.searchBar.delegate = self

        self.tabsScroll.showsHorizontalScrollIndicator = false
        self.tabsStack.axis = .horizontal
        self.tabsStack.spacing = 8.0
        self.tabsStack.translatesAutoresizingMaskIntoConstraints = false
        self.tabsScroll.addSubview(self.tabsStack)

        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.keyboardDismissMode = .onDrag
        self.tableView.rowHeight = 76.0
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(self.pulled(_:)), for: .valueChanged)
        self.tableView.refreshControl = refresh
        self.footer.textAlignment = .center
        self.footer.numberOfLines = 0
        self.footer.font = UIFont.systemFont(ofSize: 14.0)
        self.footer.textColor = .secondaryLabel
        self.footer.isUserInteractionEnabled = true
        self.footer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.footerTapped)))

        for v in [self.searchBar, self.tabsScroll, self.tableView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            self.searchBar.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor),
            self.searchBar.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 4.0),
            self.searchBar.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -4.0),
            self.tabsScroll.topAnchor.constraint(equalTo: self.searchBar.bottomAnchor),
            self.tabsScroll.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.tabsScroll.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.tabsScroll.heightAnchor.constraint(equalToConstant: 44.0),
            self.tabsStack.leadingAnchor.constraint(equalTo: self.tabsScroll.contentLayoutGuide.leadingAnchor, constant: 12.0),
            self.tabsStack.trailingAnchor.constraint(equalTo: self.tabsScroll.contentLayoutGuide.trailingAnchor, constant: -12.0),
            self.tabsStack.centerYAnchor.constraint(equalTo: self.tabsScroll.frameLayoutGuide.centerYAnchor),
            self.tabsStack.heightAnchor.constraint(equalToConstant: 30.0),
            self.tableView.topAnchor.constraint(equalTo: self.tabsScroll.bottomAnchor),
            self.tableView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.tableView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.tableView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])

        let cache = LuckgramAgentMarket.cache(accountId: self.accountId)
        self.categories = cache.categories
        self.items = cache.firstPage(category: "")?.items ?? []
        self.buildTabs()
        self.refreshCategories()
        self.reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let selected = self.tableView.indexPathForSelectedRow {
            self.tableView.deselectRow(at: selected, animated: animated)
        }
    }

    // MARK: Loading

    @objc private func pulled(_ sender: UIRefreshControl) {
        self.refreshCategories()
        self.reload()
    }

    @objc private func footerTapped() {
        if self.error != nil && !self.loading {
            self.reload()
        }
    }

    private func refreshCategories() {
        self.categoriesDisposable.set((LuckgramAgentMarket.loadCategories(accountId: self.accountId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] categories in
            guard let self else {
                return
            }
            self.categories = categories
            if !self.category.isEmpty && !categories.contains(where: { $0.id == self.category }) {
                self.category = ""
                self.reload()
            }
            self.buildTabs()
        }, error: { _ in }))
    }

    private func buildTabs() {
        for v in self.tabsStack.arrangedSubviews {
            v.removeFromSuperview()
        }
        let zh = LuckgramStrings.isChinese
        var tabs: [(String, String)] = [("", LuckgramStrings.pick("全部", "All"))]
        for c in self.categories where c.count > 0 || c.id == self.category {
            tabs.append((c.id, c.name.pick(chinese: zh)))
        }
        for (id, title) in tabs {
            let selected = id == self.category
            var config = selected ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            config.title = title
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 14.0, bottom: 4.0, trailing: 14.0)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                guard let self, self.category != id else {
                    return
                }
                self.category = id
                self.buildTabs()
                self.reload()
            })
            button.isSelected = selected
            self.tabsStack.addArrangedSubview(button)
        }
    }

    private func reload() {
        self.searchTimer?.invalidate()
        self.nextCursor = nil
        self.load(cursor: nil)
    }

    private func load(cursor: String?) {
        self.generation += 1
        let generation = self.generation
        let first = cursor == nil
        let category = self.category
        let query = self.query
        self.loading = true
        self.error = nil
        if first {
            // show what we have for this tab while loading
            self.items = LuckgramAgentMarket.cache(accountId: self.accountId).offline(category: category, query: query)
        }
        self.updateFooter()
        self.tableView.reloadData()
        self.pageDisposable.set((LuckgramAgentMarket.loadPage(accountId: self.accountId, category: category, query: query, cursor: cursor)
        |> deliverOnMainQueue).startStrict(next: { [weak self] page in
            guard let self, generation == self.generation else {
                return
            }
            self.loading = false
            self.offline = false
            if first {
                self.items = []
            }
            for agent in page.items where !self.items.contains(where: { $0.id == agent.id }) {
                self.items.append(agent)
            }
            self.nextCursor = page.nextCursor
            self.tableView.refreshControl?.endRefreshing()
            self.updateFooter()
            self.tableView.reloadData()
        }, error: { [weak self] error in
            guard let self, generation == self.generation else {
                return
            }
            self.loading = false
            self.tableView.refreshControl?.endRefreshing()
            if error.code == LuckgramAIError.cancelled {
                return
            }
            self.error = error
            self.offline = first && !self.items.isEmpty
            self.nextCursor = nil
            self.updateFooter()
            self.tableView.reloadData()
        }))
    }

    private func updateFooter() {
        let text: String
        var tappable = false
        if self.loading {
            text = LuckgramStrings.pick("加载中…", "Loading…")
        } else if let error = self.error {
            text = self.offline
                ? LuckgramStrings.pick("离线，显示的是缓存。点此重试", "Offline: showing saved results. Tap to retry")
                : LuckgramStrings.errorMessage(error.code) + "\n" + LuckgramStrings.pick("点此重试", "Tap to retry")
            tappable = true
        } else if self.items.isEmpty {
            text = self.query.isEmpty ? LuckgramStrings.pick("这里还没有智能体", "No agents here yet") : LuckgramStrings.pick("没有找到相关智能体", "No matching agents")
        } else {
            text = ""
        }
        self.footer.text = text
        self.footer.textColor = tappable ? self.view.tintColor : .secondaryLabel
        self.footer.frame = CGRect(x: 0.0, y: 0.0, width: self.tableView.bounds.width, height: text.isEmpty ? 1.0 : 72.0)
        self.tableView.tableFooterView = self.footer
    }

    // MARK: Search

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q == self.query {
            return
        }
        self.query = q
        self.searchTimer?.invalidate()
        self.searchTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.reload()
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let agent = self.items[indexPath.row]
        let zh = LuckgramStrings.isChinese
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        config.text = agent.name.pick(chinese: zh)
        config.textProperties.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
        config.secondaryText = agent.description.pick(chinese: zh) + "\n" + LuckgramAgentMarketLogic.formatUsers(agent.users, chinese: zh)
        config.secondaryTextProperties.color = .secondaryLabel
        config.secondaryTextProperties.numberOfLines = 2
        config.image = LuckgramAgentMarket.avatarImage(agent, size: 46.0)
        config.imageProperties.maximumSize = CGSize(width: 46.0, height: 46.0)
        cell.contentConfiguration = config
        cell.accessoryView = agent.proOnly ? LuckgramAgentMarket.proBadge() : nil
        cell.accessibilityLabel = config.text.map { $0 + (agent.proOnly ? ", Pro" : "") }
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if !self.loading, let cursor = self.nextCursor, indexPath.row >= self.items.count - 4 {
            self.load(cursor: cursor)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let controller = LuckgramAgentDetailController(context: self.context, host: self.host, agent: self.items[indexPath.row])
        (self.parent ?? self).navigationController?.pushViewController(controller, animated: true)
    }
}

// MARK: - Detail (spec 30 需求 3)

final class LuckgramAgentDetailController: UIViewController {
    private let context: AccountContext
    private weak var host: LuckgramAIChatHost?
    private var agent: LuckgramAgentMarketLogic.Agent
    private var unavailable = false
    private let disposable = MetaDisposable()

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let proBadge = LuckgramAgentMarket.proBadge()
    private let metaLabel = UILabel()
    private let descLabel = UILabel()
    private let examplesHeader = UILabel()
    private let examplesStack = UIStackView()
    private let noteLabel = UILabel()
    private let button = UIButton(configuration: .filled())

    init(context: AccountContext, host: LuckgramAIChatHost?, agent: LuckgramAgentMarketLogic.Agent) {
        self.context = context
        self.host = host
        self.agent = agent
        super.init(nibName: nil, bundle: nil)
        if agent.examples.isEmpty, let cached = LuckgramAgentMarket.cache(accountId: context.account.id.int64).detail(agent.id) {
            self.agent = cached
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable.dispose()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.title = LuckgramStrings.pick("智能体", "Agent")

        self.nameLabel.font = UIFont.systemFont(ofSize: 22.0, weight: .bold)
        self.nameLabel.numberOfLines = 0
        self.nameLabel.textAlignment = .center
        self.metaLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.metaLabel.textColor = .secondaryLabel
        self.metaLabel.textAlignment = .center
        self.descLabel.font = UIFont.systemFont(ofSize: 15.0)
        self.descLabel.numberOfLines = 0
        self.descLabel.textAlignment = .center
        self.examplesHeader.text = LuckgramStrings.pick("可以这样问", "Try asking")
        self.examplesHeader.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
        self.examplesHeader.textColor = self.view.tintColor
        self.examplesStack.axis = .vertical
        self.examplesStack.spacing = 8.0
        self.noteLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.noteLabel.textColor = .secondaryLabel
        self.noteLabel.numberOfLines = 0
        self.noteLabel.textAlignment = .center
        self.avatarView.widthAnchor.constraint(equalToConstant: 88.0).isActive = true
        self.avatarView.heightAnchor.constraint(equalToConstant: 88.0).isActive = true

        let nameRow = UIStackView(arrangedSubviews: [self.nameLabel, self.proBadge])
        nameRow.axis = .horizontal
        nameRow.spacing = 8.0
        nameRow.alignment = .center
        let header = UIStackView(arrangedSubviews: [self.avatarView, nameRow, self.metaLabel, self.descLabel])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 8.0
        header.setCustomSpacing(14.0, after: self.avatarView)
        let stack = UIStackView(arrangedSubviews: [header, self.examplesHeader, self.examplesStack, self.noteLabel])
        stack.axis = .vertical
        stack.spacing = 8.0
        stack.setCustomSpacing(24.0, after: header)
        stack.setCustomSpacing(16.0, after: self.examplesStack)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(scroll)
        scroll.addSubview(stack)

        var config = UIButton.Configuration.filled()
        config.title = LuckgramStrings.pick("开始聊天", "Start chat")
        config.cornerStyle = .large
        self.button.configuration = config
        self.button.translatesAutoresizingMaskIntoConstraints = false
        self.button.addAction(UIAction { [weak self] _ in
            self?.startChat()
        }, for: .touchUpInside)
        self.view.addSubview(self.button)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: self.view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: self.button.topAnchor, constant: -8.0),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24.0),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24.0),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20.0),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20.0),
            self.button.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 16.0),
            self.button.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -16.0),
            self.button.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -16.0),
            self.button.heightAnchor.constraint(equalToConstant: 50.0)
        ])
        self.bind()

        self.disposable.set((LuckgramAgentMarket.loadDetail(accountId: self.context.account.id.int64, id: self.agent.id)
        |> deliverOnMainQueue).startStrict(next: { [weak self] agent in
            self?.agent = agent
            self?.unavailable = false
            self?.bind()
        }, error: { [weak self] error in
            // 404: taken down; other errors keep the cached copy (offline, 需求 7)
            self?.unavailable = error.httpStatus == 404 || error.code == LuckgramAIError.agentUnavailable
            self?.bind()
        }))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if self.isViewLoaded {
            self.bind() // Pro may have changed after the upgrade page
        }
    }

    private func bind() {
        let zh = LuckgramStrings.isChinese
        self.avatarView.image = LuckgramAgentMarket.avatarImage(self.agent, size: 88.0)
        self.nameLabel.text = self.agent.name.pick(chinese: zh)
        self.proBadge.isHidden = !self.agent.proOnly
        let author = self.agent.author == "luckgram" ? LuckgramStrings.pick("Luckgram 官方", "By Luckgram") : self.agent.author
        self.metaLabel.text = author + " · " + LuckgramAgentMarketLogic.formatUsers(self.agent.users, chinese: zh)
        self.descLabel.text = self.agent.description.pick(chinese: zh)

        for v in self.examplesStack.arrangedSubviews {
            v.removeFromSuperview()
        }
        let examples = Array(self.agent.examples.prefix(3))
        self.examplesHeader.isHidden = examples.isEmpty
        for example in examples {
            let label = LuckgramAgentMarket.PaddedExampleLabel()
            label.text = example.pick(chinese: zh)
            label.font = UIFont.systemFont(ofSize: 15.0)
            label.numberOfLines = 0
            label.backgroundColor = .secondarySystemBackground
            label.layer.cornerRadius = 12.0
            label.layer.masksToBounds = true
            self.examplesStack.addArrangedSubview(label)
        }

        if self.unavailable {
            self.noteLabel.text = LuckgramStrings.pick("这个智能体已下架。", "This agent is no longer available.")
            self.noteLabel.isHidden = false
        } else if LuckgramAgentMarketLogic.needsUpgrade(self.agent, isPro: LuckgramPro.shared.isPro) {
            self.noteLabel.text = LuckgramStrings.pick("Luckgram Pro 专享，升级后即可聊天。", "Available with Luckgram Pro.")
            self.noteLabel.isHidden = false
        } else {
            self.noteLabel.isHidden = true
        }
        self.button.isEnabled = !self.unavailable
    }

    private func startChat() {
        if self.unavailable {
            return
        }
        LuckgramAgentMarket.open(self.agent, context: self.context, from: self, host: self.host)
    }
}

extension LuckgramAgentMarket {
    final class PaddedExampleLabel: UILabel {
        private let insets = UIEdgeInsets(top: 10.0, left: 14.0, bottom: 10.0, right: 14.0)

        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: self.insets))
        }

        override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
            let rect = super.textRect(forBounds: bounds.inset(by: self.insets), limitedToNumberOfLines: numberOfLines)
            return rect.inset(by: UIEdgeInsets(top: -self.insets.top, left: -self.insets.left, bottom: -self.insets.bottom, right: -self.insets.right))
        }
    }
}
