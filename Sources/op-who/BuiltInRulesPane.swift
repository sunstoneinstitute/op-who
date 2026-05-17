import AppKit
import OpWhoLib

/// Built-in Rules tab inside the Configure window. Read-only view of
/// `RequestRule.builtIns` with a per-row enable checkbox. Users who
/// want to customize a built-in click "Copy as User Rule" — the
/// built-in is then disabled and an editable clone shows up in the
/// User Rules tab.
final class BuiltInRulesPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let store: RequestRuleStore
    weak var presenter: NSWindow?

    private let tableView = NSTableView()
    private var selectedIndex: Int? {
        tableView.selectedRow >= 0 ? tableView.selectedRow : nil
    }

    /// Callback fired after a "Copy as User Rule" action completes. The
    /// ConfigWindowController hooks this to switch to the User Rules tab
    /// AND tell the RulesPane to reload its table and select the new clone
    /// (identified by the supplied UUID) so the detail form shows the
    /// cloned matcher right away instead of whatever was previously
    /// selected.
    var onCopyToUserRules: ((UUID) -> Void)?

    private(set) lazy var view: NSView = makeContentView()

    init(store: RequestRuleStore) {
        self.store = store
        super.init()
        _ = view
        tableView.reloadData()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let container = NSView()

        let header = NSTextField(labelWithString: "Built-in rules (shipped with op-who)")
        header.font = NSFont.boldSystemFont(ofSize: 13)

        let subhead = NSTextField(labelWithString:
            "Uncheck to disable a built-in. Editing is not allowed — to customize one, " +
            "click \"Copy as User Rule\" to clone it into the User Rules tab; the original " +
            "built-in is disabled automatically so the two don't both match."
        )
        subhead.font = NSFont.systemFont(ofSize: 11)
        subhead.textColor = .secondaryLabelColor
        subhead.lineBreakMode = .byWordWrapping
        subhead.maximumNumberOfLines = 3

        let tableScroll = makeTableScroll()
        let buttonBar = makeButtonBar()

        for v in [header, subhead, tableScroll, buttonBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        let padding: CGFloat = 16
        let spacing: CGFloat = 10
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            subhead.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            subhead.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            tableScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            tableScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            buttonBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            buttonBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            subhead.topAnchor.constraint(equalTo: header.bottomAnchor, constant: spacing),
            tableScroll.topAnchor.constraint(equalTo: subhead.bottomAnchor, constant: spacing),
            buttonBar.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: spacing),
            buttonBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        return container
    }

    private func makeTableScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let enabledCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabledCol.title = "On"
        enabledCol.width = 32
        enabledCol.minWidth = 28
        enabledCol.maxWidth = 50
        tableView.addTableColumn(enabledCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 220
        tableView.addTableColumn(nameCol)

        let whenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("when"))
        whenCol.title = "When"
        whenCol.width = 260
        tableView.addTableColumn(whenCol)

        let thenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("then"))
        thenCol.title = "Then"
        thenCol.width = 260
        tableView.addTableColumn(thenCol)

        scroll.documentView = tableView
        return scroll
    }

    private func makeButtonBar() -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8

        let copyButton = NSButton(title: "Copy as User Rule", target: self, action: #selector(copyAction(_:)))
        bar.addArrangedSubview(copyButton)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        let enableAll = NSButton(title: "Enable All", target: self, action: #selector(enableAllAction(_:)))
        bar.addArrangedSubview(enableAll)

        return bar
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        RequestRule.builtIns.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let rule = RequestRule.builtIns[row]
        switch col.identifier.rawValue {
        case "enabled":
            let id = NSUserInterfaceItemIdentifier("cell_enabled")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? CheckboxCellView)
                ?? CheckboxCellView(identifier: id)
            cell.button.target = self
            cell.button.action = #selector(toggleEnabled(_:))
            cell.button.tag = row
            // builtInID is guaranteed non-nil for built-ins; fall back
            // defensively so a hypothetical buggy entry doesn't crash.
            let isDisabled = rule.builtInID.map { store.disabledBuiltInIDs.contains($0) } ?? false
            cell.button.state = isDisabled ? .off : .on
            return cell
        default:
            let id = NSUserInterfaceItemIdentifier("cell_\(col.identifier.rawValue)")
            let cell: NSTableCellView = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
                ?? makeTextCellView(id: id)
            switch col.identifier.rawValue {
            case "name":
                cell.textField?.stringValue = rule.name
            case "when":
                cell.textField?.stringValue = rule.matcher.displaySummary
                cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            case "then":
                cell.textField?.stringValue = rule.template
                cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            default: break
            }
            // Dim text for disabled built-ins so the table reads at a
            // glance — same affordance as the User Rules pane.
            let isDisabled = rule.builtInID.map { store.disabledBuiltInIDs.contains($0) } ?? false
            cell.textField?.textColor = isDisabled ? .tertiaryLabelColor : .labelColor
            return cell
        }
    }

    private func makeTextCellView(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        cell.addSubview(tf)
        cell.textField = tf
        cell.identifier = id
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < RequestRule.builtIns.count else { return }
        guard let id = RequestRule.builtIns[row].builtInID else { return }
        store.setBuiltInDisabled(id: id, disabled: sender.state == .off)
        // Refresh just this row to update its text color.
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    @objc private func enableAllAction(_ sender: Any?) {
        store.enableAllBuiltIns()
        tableView.reloadData()
    }

    @objc private func copyAction(_ sender: Any?) {
        guard let row = selectedIndex, row < RequestRule.builtIns.count else {
            NSSound.beep()
            return
        }
        let source = RequestRule.builtIns[row]
        // Disable the original so the clone (which runs first as a
        // user rule) doesn't also fire the built-in.
        if let id = source.builtInID {
            store.setBuiltInDisabled(id: id, disabled: true)
        }
        // Clone with a fresh UUID, name suffix, and no builtInID so
        // the new entry is a true user rule.
        let clone = RequestRule(
            id: UUID(),
            name: source.name + " (copy)",
            matcher: source.matcher,
            template: source.template,
            replacesActor: source.replacesActor,
            kind: source.kind,
            isWarning: source.isWarning,
            builtInID: nil
        )
        store.setUserRules(store.userRules + [clone])
        tableView.reloadData()
        onCopyToUserRules?(clone.id)
    }
}

/// Cell view containing a single checkbox — built-in cells can't reuse
/// the default `NSTableCellView` because that's tuned for a text field.
private final class CheckboxCellView: NSTableCellView {
    let button: NSButton = {
        let b = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
