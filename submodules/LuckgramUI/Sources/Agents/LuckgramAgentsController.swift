import Foundation
import UIKit
import AccountContext

/// spec 22 需求 1: presets, the user's agents and "创建你自己的智能体".
final class LuckgramAgentsController: UITableViewController {
    private let context: AccountContext
    private weak var host: LuckgramAIChatHost?
    private var custom: [LuckgramAgents.Agent] = []

    private var accountId: Int64 {
        return self.context.account.id.int64
    }

    init(context: AccountContext, host: LuckgramAIChatHost?) {
        self.context = context
        self.host = host
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = LuckgramStrings.pick("智能体", "Agents")
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "agent")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.custom = LuckgramAgents.custom(accountId: self.accountId)
        self.tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? LuckgramStrings.pick("热门智能体", "Popular agents") : LuckgramStrings.pick("我的智能体", "My agents")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? LuckgramAgents.presets.count : self.custom.count + 1
    }

    private func agent(at indexPath: IndexPath) -> LuckgramAgents.Agent? {
        if indexPath.section == 0 {
            return LuckgramAgents.presets[indexPath.row]
        }
        return indexPath.row < self.custom.count ? self.custom[indexPath.row] : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        if let agent = self.agent(at: indexPath) {
            config.text = agent.name
            config.secondaryText = agent.description
            config.secondaryTextProperties.color = .secondaryLabel
            config.image = LuckgramAgents.avatarImage(agent, size: 40.0)
            config.imageProperties.maximumSize = CGSize(width: 40.0, height: 40.0)
            let more = UIButton(type: .system)
            more.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            more.accessibilityLabel = LuckgramStrings.pick("更多", "More")
            more.frame = CGRect(x: 0.0, y: 0.0, width: 36.0, height: 36.0)
            more.showsMenuAsPrimaryAction = true
            more.menu = self.menu(for: agent)
            cell.accessoryView = more
        } else {
            config.text = LuckgramStrings.pick("创建你自己的智能体", "Create your own agent")
            config.textProperties.color = self.view.tintColor
            config.image = UIImage(systemName: "plus.circle.fill")
        }
        cell.contentConfiguration = config
        return cell
    }

    private func menu(for agent: LuckgramAgents.Agent) -> UIMenu {
        let pinned = LuckgramAgents.isPinned(agent.id, accountId: self.accountId)
        var actions: [UIMenuElement] = [
            UIAction(title: LuckgramStrings.pick("开始对话", "Open chat"), image: UIImage(systemName: "bubble.left")) { [weak self] _ in
                self?.open(agent)
            },
            UIAction(title: pinned ? LuckgramStrings.pick("从聊天列表移除", "Remove from chat list") : LuckgramStrings.pick("添加到聊天列表", "Add to chat list"), image: UIImage(systemName: pinned ? "pin.slash" : "pin")) { [weak self] _ in
                guard let self else {
                    return
                }
                LuckgramAgents.setPinned(agent.id, !pinned, accountId: self.accountId)
                self.tableView.reloadData()
            }
        ]
        if !agent.isPreset {
            actions.append(UIAction(title: LuckgramStrings.pick("编辑", "Edit"), image: UIImage(systemName: "pencil")) { [weak self] _ in
                guard let self else {
                    return
                }
                self.navigationController?.pushViewController(LuckgramAgentEditController(context: self.context, agent: agent), animated: true)
            })
            actions.append(UIAction(title: LuckgramStrings.pick("删除", "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmDelete(agent)
            })
        }
        return UIMenu(children: actions)
    }

    private func confirmDelete(_ agent: LuckgramAgents.Agent) {
        let alert = UIAlertController(title: LuckgramStrings.pick("删除智能体", "Delete agent"), message: LuckgramStrings.pick("「\(agent.name)」和它的对话都会删除。", "\"\(agent.name)\" and its chat will be deleted."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("删除", "Delete"), style: .destructive) { [weak self] _ in
            guard let self else {
                return
            }
            LuckgramAgents.delete(agent, context: self.context)
            self.custom = LuckgramAgents.custom(accountId: self.accountId)
            self.tableView.reloadData()
        })
        self.present(alert, animated: true)
    }

    private func open(_ agent: LuckgramAgents.Agent) {
        LuckgramAgents.open(agent, context: self.context, from: self.host)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let agent = self.agent(at: indexPath) {
            self.open(agent)
        } else {
            self.navigationController?.pushViewController(LuckgramAgentEditController(context: self.context, agent: nil), animated: true)
        }
    }
}

/// spec 22 需求 4: create or edit a custom agent (name ≤ 30, description, instruction ≤ 4000, color).
final class LuckgramAgentEditController: UIViewController, UITextFieldDelegate, UITextViewDelegate {
    private let context: AccountContext
    private var agent: LuckgramAgents.Agent
    private let isNew: Bool
    private let nameField = UITextField()
    private let descField = UITextField()
    private let promptView = UITextView()
    private var colorButtons: [UIButton] = []

    init(context: AccountContext, agent: LuckgramAgents.Agent?) {
        self.context = context
        self.isNew = agent == nil
        self.agent = agent ?? .custom(name: "", description: "", prompt: "", color: LuckgramAgents.colors[0])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemGroupedBackground
        self.title = self.isNew ? LuckgramStrings.pick("创建智能体", "New agent") : LuckgramStrings.pick("编辑智能体", "Edit agent")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(self.savePressed))

        func label(_ text: String) -> UILabel {
            let l = UILabel()
            l.text = text
            l.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
            l.textColor = .secondaryLabel
            return l
        }
        func style(_ v: UIView) {
            v.backgroundColor = .secondarySystemGroupedBackground
            v.layer.cornerRadius = 10.0
        }
        self.nameField.placeholder = LuckgramStrings.pick("例如：只用英文回答的翻译官", "e.g. English-only translator")
        self.nameField.text = self.agent.name
        self.nameField.delegate = self
        self.descField.placeholder = LuckgramStrings.pick("一句话说明它做什么", "One line about what it does")
        self.descField.text = self.agent.description
        self.descField.delegate = self
        for field in [self.nameField, self.descField] {
            style(field)
            field.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 12.0, height: 1.0))
            field.leftViewMode = .always
            field.heightAnchor.constraint(equalToConstant: 44.0).isActive = true
        }
        self.promptView.text = self.agent.prompt
        self.promptView.font = UIFont.systemFont(ofSize: 16.0)
        self.promptView.delegate = self
        self.promptView.textContainerInset = UIEdgeInsets(top: 10.0, left: 8.0, bottom: 10.0, right: 8.0)
        style(self.promptView)
        self.promptView.heightAnchor.constraint(equalToConstant: 180.0).isActive = true
        let promptHint = UILabel()
        promptHint.text = LuckgramStrings.pick("告诉它是谁、怎么回答，例如：你是翻译官，无论用户说什么语言，都只用英文回答。", "Who it is and how to answer, e.g. You are a translator. Always answer in English only.")
        promptHint.font = UIFont.systemFont(ofSize: 12.0)
        promptHint.textColor = .secondaryLabel
        promptHint.numberOfLines = 0

        let colors = UIStackView()
        colors.axis = .horizontal
        colors.spacing = 10.0
        for (i, value) in LuckgramAgents.colors.enumerated() {
            let button = UIButton(type: .custom)
            var sample = LuckgramAgents.Agent.custom(name: "", description: "", prompt: "", color: value)
            sample.id = ""
            button.backgroundColor = sample.uiColor
            button.layer.cornerRadius = 16.0
            button.tag = i
            button.addTarget(self, action: #selector(self.colorPressed(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 32.0).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32.0).isActive = true
            colors.addArrangedSubview(button)
            self.colorButtons.append(button)
        }

        var arranged: [UIView] = [label(LuckgramStrings.pick("名称", "Name")), self.nameField, label(LuckgramStrings.pick("简介", "Description")), self.descField, label(LuckgramStrings.pick("指令", "Instructions")), self.promptView, promptHint, label(LuckgramStrings.pick("头像颜色", "Avatar color")), colors]
        if !self.isNew {
            let delete = UIButton(type: .system, primaryAction: UIAction(title: LuckgramStrings.pick("删除智能体", "Delete agent")) { [weak self] _ in
                self?.confirmDelete()
            })
            delete.tintColor = .systemRed
            arranged.append(delete)
        }
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.spacing = 8.0
        stack.setCustomSpacing(16.0, after: self.nameField)
        stack.setCustomSpacing(16.0, after: self.descField)
        stack.setCustomSpacing(16.0, after: promptHint)
        stack.setCustomSpacing(24.0, after: colors)
        stack.alignment = .fill
        colors.alignment = .center
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: self.view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: self.view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16.0),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24.0),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20.0),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20.0)
        ])
        self.updateColors()
    }

    private func updateColors() {
        for button in self.colorButtons {
            let selected = LuckgramAgents.colors[button.tag] == self.agent.color
            button.layer.borderWidth = selected ? 3.0 : 0.0
            button.layer.borderColor = UIColor.label.cgColor
            button.accessibilityLabel = selected ? LuckgramStrings.pick("已选", "Selected") : nil
        }
    }

    @objc private func colorPressed(_ sender: UIButton) {
        self.agent.color = LuckgramAgents.colors[sender.tag]
        self.updateColors()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = (textField.text ?? "") as NSString
        let updated = current.replacingCharacters(in: range, with: string)
        return updated.count <= (textField === self.nameField ? LuckgramAgents.maxName : 100)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let updated = ((textView.text ?? "") as NSString).replacingCharacters(in: range, with: text)
        return updated.count <= LuckgramAgents.maxPrompt
    }

    private func showError(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("好", "OK"), style: .default))
        self.present(alert, animated: true)
    }

    @objc private func savePressed() {
        let name = (self.nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = self.promptView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            self.showError(LuckgramStrings.pick("请填写名称", "Please enter a name"))
            return
        }
        if prompt.isEmpty {
            self.showError(LuckgramStrings.pick("请填写指令", "Please enter instructions"))
            return
        }
        let description = (self.descField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = LuckgramAgents.Agent.custom(name: name, description: description, prompt: prompt, color: self.agent.color, id: self.agent.id)
        LuckgramAgents.save(saved, accountId: self.context.account.id.int64)
        self.navigationController?.popViewController(animated: true)
    }

    private func confirmDelete() {
        let agent = self.agent
        let alert = UIAlertController(title: LuckgramStrings.pick("删除智能体", "Delete agent"), message: LuckgramStrings.pick("「\(agent.name)」和它的对话都会删除。", "\"\(agent.name)\" and its chat will be deleted."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("取消", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LuckgramStrings.pick("删除", "Delete"), style: .destructive) { [weak self] _ in
            guard let self else {
                return
            }
            LuckgramAgents.delete(agent, context: self.context)
            self.navigationController?.popViewController(animated: true)
        })
        self.present(alert, animated: true)
    }
}
