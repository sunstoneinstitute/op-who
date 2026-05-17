import AppKit
import OpWhoLib

/// User Rules tab inside the Configure window. Master/detail editor for
/// the user-authored rule list (which runs *before* any enabled built-in
/// via `RequestRuleStore.allRules`). Hosted by `ConfigWindowController`
/// via an NSTabView; owns no window of its own. The `view` property is
/// built lazily and kept; the host adds it to the tab item.
///
/// `presenter` is a weak reference to the window that should own any
/// modal sheet this pane opens (the "Add rule from recent request"
/// picker). It's set after the host window exists, in the
/// `ConfigWindowController` init.
final class RulesPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let store: RequestRuleStore
    private let recentStore: RecentRequestsStore
    weak var presenter: NSWindow?

    private let tableView = NSTableView()
    private var selectedIndex: Int? { tableView.selectedRow >= 0 ? tableView.selectedRow : nil }
    private var addSheet: AddRuleSheetController?

    // Detail form controls.
    private let nameField = NSTextField()
    private let processNameField = NSTextField()
    private let subcommandField = NSTextField()
    private let argvContainsAllField = NSTextField()
    private let triggerCwdPrefixField = NSTextField()
    private let binaryVerifiedPopup = NSPopUpButton()
    private let pluginUpdatePopup = NSPopUpButton()
    private let regexSourcePopup = NSPopUpButton()
    private let regexPatternField = NSTextField()
    private let templateField = NSTextField()
    private let replacesActorCheckbox = NSButton(checkboxWithTitle: "Replaces actor (full title)", target: nil, action: nil)
    private let isWarningCheckbox = NSButton(checkboxWithTitle: "Render as warning", target: nil, action: nil)
    private let kindPopup = NSPopUpButton()

    private(set) lazy var view: NSView = makeContentView()

    init(store: RequestRuleStore, recentStore: RecentRequestsStore) {
        self.store = store
        self.recentStore = recentStore
        super.init()
        _ = view // force-build so initial selection takes effect
        reloadTable()
        if !store.userRules.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let container = NSView()

        let header = NSTextField(labelWithString: "User-authored rules (evaluated before built-ins)")
        header.font = NSFont.boldSystemFont(ofSize: 13)

        let subhead = NSTextField(labelWithString:
            "Rules in this list run before any enabled built-in, so you can shadow a built-in without disabling it. " +
            "Each rule's matcher is evaluated against the trigger process, its argv, and its cwd; first match wins."
        )
        subhead.font = NSFont.systemFont(ofSize: 11)
        subhead.textColor = .secondaryLabelColor
        subhead.lineBreakMode = .byWordWrapping
        subhead.maximumNumberOfLines = 2

        let tableScroll = makeTableScroll()
        let buttonBar = makeButtonBar()
        let detail = makeDetailForm()

        for v in [header, subhead, tableScroll, buttonBar, detail] {
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
            detail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            subhead.topAnchor.constraint(equalTo: header.bottomAnchor, constant: spacing),
            tableScroll.topAnchor.constraint(equalTo: subhead.bottomAnchor, constant: spacing),
            buttonBar.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: spacing),
            detail.topAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: spacing),
            detail.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
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

        let indexCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("index"))
        indexCol.title = "#"
        indexCol.width = 30
        indexCol.minWidth = 24
        indexCol.maxWidth = 50
        tableView.addTableColumn(indexCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 200
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

        let addRemove = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "plus", accessibilityDescription: "Add rule")!,
                NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove selected rule")!,
            ],
            trackingMode: .momentary,
            target: self,
            action: #selector(addRemoveAction(_:))
        )
        addRemove.segmentStyle = .smallSquare
        bar.addArrangedSubview(addRemove)

        let upDown = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Move up")!,
                NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Move down")!,
            ],
            trackingMode: .momentary,
            target: self,
            action: #selector(moveAction(_:))
        )
        upDown.segmentStyle = .smallSquare
        bar.addArrangedSubview(upDown)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        let reset = NSButton(title: "Remove All", target: self, action: #selector(resetAction(_:)))
        bar.addArrangedSubview(reset)

        return bar
    }

    private func makeDetailForm() -> NSView {
        let box = NSBox()
        box.title = "Selected rule"
        box.titleFont = NSFont.systemFont(ofSize: 11)

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 8

        configureField(nameField, placeholder: "Display name")
        configureField(processNameField, placeholder: "comma-separated, e.g. op,ssh,git")
        configureField(subcommandField, placeholder: "comma-separated, e.g. fetch,pull,push")
        configureField(argvContainsAllField, placeholder: "comma-separated tokens that must all appear in argv")
        configureField(triggerCwdPrefixField, placeholder: "e.g. ~/.claude/plugins/")
        configureField(regexPatternField, placeholder: #"e.g. github\.com[:/](.+?)(?:\.git)?/?$ — capture groups become $1, $2, …"#)
        configureField(templateField, placeholder: "Template — {process}, {subcommand}, {argv}, {cwd}, {op_uri}, {op_phrase}, {plugin_remote}, {repo}, {source}, {marketplace}, {argv[N]}, $0, $1, …")

        binaryVerifiedPopup.addItems(withTitles: ["any", "verified", "unverified"])
        binaryVerifiedPopup.target = self
        binaryVerifiedPopup.action = #selector(detailChanged(_:))

        pluginUpdatePopup.addItems(withTitles: ["any", "required", "must not be present"])
        pluginUpdatePopup.target = self
        pluginUpdatePopup.action = #selector(detailChanged(_:))

        // Index 0 is "(none)" — disables the regex predicate entirely.
        // Subsequent items are the RegexCaptureSource cases, in
        // declaration order, displayed by rawValue.
        regexSourcePopup.addItems(withTitles: ["(none)"] + RegexCaptureSource.allCases.map { $0.rawValue })
        regexSourcePopup.target = self
        regexSourcePopup.action = #selector(detailChanged(_:))

        kindPopup.addItems(withTitles: [
            RequestKind.onePasswordCLI.rawValue,
            RequestKind.unverifiedOp.rawValue,
            RequestKind.ssh.rawValue,
            RequestKind.unknown.rawValue,
        ])
        kindPopup.target = self
        kindPopup.action = #selector(detailChanged(_:))

        replacesActorCheckbox.target = self
        replacesActorCheckbox.action = #selector(detailChanged(_:))
        isWarningCheckbox.target = self
        isWarningCheckbox.action = #selector(detailChanged(_:))

        grid.addRow(with: [label("Name"), nameField])
        grid.addRow(with: [label("Process name"), processNameField])
        grid.addRow(with: [label("Subcommand"), subcommandField])
        grid.addRow(with: [label("argv contains all"), argvContainsAllField])
        grid.addRow(with: [label("Trigger CWD prefix"), triggerCwdPrefixField])
        grid.addRow(with: [label("Binary verified"), binaryVerifiedPopup])
        grid.addRow(with: [label("Plugin update"), pluginUpdatePopup])
        grid.addRow(with: [label("Regex source"), regexSourcePopup])
        grid.addRow(with: [label("Regex pattern"), regexPatternField])
        grid.addRow(with: [label("Template"), templateField])
        grid.addRow(with: [label("Kind"), kindPopup])
        grid.addRow(with: [NSView(), replacesActorCheckbox])
        grid.addRow(with: [NSView(), isWarningCheckbox])

        grid.column(at: 0).xPlacement = .leading
        // Pin column 0 to a width that fits the widest label ("Trigger CWD
        // prefix") with a little breathing room. Without an explicit width
        // NSGridView dumps slack from the stretched grid into column 0,
        // which leaves the editable fields stranded against the right edge
        // instead of sitting right next to their labels.
        grid.column(at: 0).width = 140
        grid.column(at: 1).xPlacement = .fill

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        box.contentView = content
        return box
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(detailChanged(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.alignment = .left
        return l
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { store.userRules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell_\(col.identifier.rawValue)")
        let cell: NSTableCellView = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCellView(id: id)
        let rule = store.userRules[row]
        switch col.identifier.rawValue {
        case "index": cell.textField?.stringValue = String(row + 1)
        case "name": cell.textField?.stringValue = rule.name
        case "when":
            cell.textField?.stringValue = rule.matcher.displaySummary
            cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        case "then":
            cell.textField?.stringValue = rule.template
            cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        default: break
        }
        return cell
    }

    private func makeCellView(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadDetailFromSelection()
    }

    // MARK: - Actions

    @objc private func addRemoveAction(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: addNewRule()
        case 1: removeSelectedRule()
        default: break
        }
    }

    @objc private func moveAction(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: moveSelected(by: -1)
        case 1: moveSelected(by: +1)
        default: break
        }
    }

    @objc private func resetAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remove all user rules?"
        alert.informativeText = "Your user-authored rules will be deleted. Built-in rules remain unchanged — manage them in the Built-in Rules tab."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearUserRules()
        reloadTable()
        loadDetailFromSelection()
    }

    @objc private func detailChanged(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        var rule = store.userRules[index]
        rule.name = nameField.stringValue
        rule.matcher = currentMatcherFromForm()
        rule.template = templateField.stringValue
        rule.replacesActor = (replacesActorCheckbox.state == .on)
        rule.isWarning = (isWarningCheckbox.state == .on)
        if let raw = kindPopup.titleOfSelectedItem,
           let kind = RequestKind(rawValue: raw) {
            rule.kind = kind
        }
        var rules = store.userRules
        rules[index] = rule
        store.setUserRules(rules)
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    // MARK: - Mutations

    private func addNewRule() {
        let recents = recentStore.requests.reversed()
        guard !recents.isEmpty else {
            insertRule(emptyTemplateRule())
            return
        }
        let sheet = AddRuleSheetController(recents: Array(recents)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .none: break
            case .some(.empty): self.insertRule(self.emptyTemplateRule())
            case .some(.fromRecent(let recent)):
                self.insertRule(self.ruleFromRecent(recent))
            }
            self.addSheet = nil
        }
        addSheet = sheet
        if let host = presenter, let sheetWindow = sheet.window {
            host.beginSheet(sheetWindow, completionHandler: nil)
        }
    }

    private func insertRule(_ rule: RequestRule) {
        var rules = store.userRules
        let target = (selectedIndex.map { $0 + 1 }) ?? rules.count
        rules.insert(rule, at: target)
        store.setUserRules(rules)
        reloadTable()
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
    }

    private func emptyTemplateRule() -> RequestRule {
        RequestRule(
            name: "New rule",
            matcher: RequestMatcher(),
            template: "triggered 1Password (via ‘{process}’)",
            kind: .unknown,
            isWarning: false
        )
    }

    private func ruleFromRecent(_ recent: RecentRequest) -> RequestRule {
        let process = recent.chainNames.first
        let sub = parseSubcommand(argv: recent.triggerArgv)
        var matcher = RequestMatcher()
        if let p = process, !p.isEmpty {
            matcher.processName = [p]
        }
        if let s = sub {
            matcher.subcommand = [s]
        }
        if process == "op" {
            matcher.binaryVerified = recent.binaryVerified
        }
        if recent.pluginRemoteURL != nil {
            matcher.requiresPluginUpdate = true
        }

        // Inherit template/kind/etc from whichever rule matched the
        // recent request — could be a user rule or a built-in.
        let inherited = recent.matchedRuleID.flatMap { id in
            store.allRules.first(where: { $0.id == id })
        }
        let template = inherited?.template ?? "triggered 1Password (via ‘{process}’)"
        let replacesActor = inherited?.replacesActor ?? false
        let kind = inherited?.kind ?? RequestKind(rawValue: recent.kindRaw) ?? .unknown
        let isWarning = inherited?.isWarning ?? recent.isWarning

        let label: String
        if let p = process, let s = sub {
            label = "Custom: \(p) \(s)"
        } else if let p = process {
            label = "Custom: \(p)"
        } else {
            label = "Custom rule"
        }
        return RequestRule(
            name: label, matcher: matcher, template: template,
            replacesActor: replacesActor, kind: kind, isWarning: isWarning
        )
    }

    private func removeSelectedRule() {
        guard let index = selectedIndex else { return }
        var rules = store.userRules
        rules.remove(at: index)
        store.setUserRules(rules)
        reloadTable()
        if !rules.isEmpty {
            let nextSelection = min(index, rules.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: nextSelection), byExtendingSelection: false)
        }
    }

    private func moveSelected(by delta: Int) {
        guard let index = selectedIndex else { return }
        let target = index + delta
        guard target >= 0, target < store.userRules.count, target != index else { return }
        var rules = store.userRules
        let rule = rules.remove(at: index)
        rules.insert(rule, at: target)
        store.setUserRules(rules)
        reloadTable()
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
    }

    // MARK: - Detail form ↔ rule

    private func loadDetailFromSelection() {
        guard let index = selectedIndex else {
            clearDetail()
            return
        }
        let rule = store.userRules[index]
        nameField.stringValue = rule.name
        processNameField.stringValue = rule.matcher.processName?.joined(separator: ",") ?? ""
        subcommandField.stringValue = rule.matcher.subcommand?.joined(separator: ",") ?? ""
        argvContainsAllField.stringValue = rule.matcher.argvContainsAll?.joined(separator: ",") ?? ""
        triggerCwdPrefixField.stringValue = rule.matcher.triggerCwdPrefix ?? ""
        switch rule.matcher.binaryVerified {
        case .none: binaryVerifiedPopup.selectItem(at: 0)
        case .some(true): binaryVerifiedPopup.selectItem(at: 1)
        case .some(false): binaryVerifiedPopup.selectItem(at: 2)
        }
        switch rule.matcher.requiresPluginUpdate {
        case .none: pluginUpdatePopup.selectItem(at: 0)
        case .some(true): pluginUpdatePopup.selectItem(at: 1)
        case .some(false): pluginUpdatePopup.selectItem(at: 2)
        }
        if let r = rule.matcher.regex {
            regexSourcePopup.selectItem(withTitle: r.source.rawValue)
            regexPatternField.stringValue = r.pattern
        } else {
            regexSourcePopup.selectItem(at: 0)
            regexPatternField.stringValue = ""
        }
        templateField.stringValue = rule.template
        replacesActorCheckbox.state = rule.replacesActor ? .on : .off
        isWarningCheckbox.state = rule.isWarning ? .on : .off
        kindPopup.selectItem(withTitle: rule.kind.rawValue)
    }

    private func clearDetail() {
        nameField.stringValue = ""
        processNameField.stringValue = ""
        subcommandField.stringValue = ""
        argvContainsAllField.stringValue = ""
        triggerCwdPrefixField.stringValue = ""
        binaryVerifiedPopup.selectItem(at: 0)
        pluginUpdatePopup.selectItem(at: 0)
        regexSourcePopup.selectItem(at: 0)
        regexPatternField.stringValue = ""
        templateField.stringValue = ""
        replacesActorCheckbox.state = .off
        isWarningCheckbox.state = .off
        kindPopup.selectItem(at: 3)
    }

    private func currentMatcherFromForm() -> RequestMatcher {
        let processName = parseCSV(processNameField.stringValue)
        let subcommand = parseCSV(subcommandField.stringValue)
        let argvContainsAll = parseCSV(argvContainsAllField.stringValue)
        let triggerCwdPrefix = triggerCwdPrefixField.stringValue.trimmingCharacters(in: .whitespaces)
        let binaryVerified: Bool? = {
            switch binaryVerifiedPopup.indexOfSelectedItem {
            case 1: return true
            case 2: return false
            default: return nil
            }
        }()
        let pluginUpdate: Bool? = {
            switch pluginUpdatePopup.indexOfSelectedItem {
            case 1: return true
            case 2: return false
            default: return nil
            }
        }()
        // Regex source popup: index 0 is "(none)" → drop the predicate.
        // Index N>0 maps to RegexCaptureSource.allCases[N-1] (same
        // ordering used to populate the menu).
        let regex: RegexCapture? = {
            let idx = regexSourcePopup.indexOfSelectedItem
            guard idx > 0, idx - 1 < RegexCaptureSource.allCases.count else { return nil }
            let pattern = regexPatternField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return nil }
            return RegexCapture(source: RegexCaptureSource.allCases[idx - 1], pattern: pattern)
        }()
        return RequestMatcher(
            processName: processName,
            subcommand: subcommand,
            argvContainsAll: argvContainsAll,
            triggerCwdPrefix: triggerCwdPrefix.isEmpty ? nil : triggerCwdPrefix,
            binaryVerified: binaryVerified,
            requiresPluginUpdate: pluginUpdate,
            regex: regex
        )
    }

    private func parseCSV(_ s: String) -> [String]? {
        let items = s
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private func reloadTable() {
        tableView.reloadData()
    }

    /// Reload the table to pick up rules appended by another pane (the
    /// Built-ins pane's "Copy as User Rule" action) and select the row
    /// matching the supplied UUID. Selecting it programmatically fires
    /// `tableViewSelectionDidChange`, which repopulates the detail form
    /// from the new clone's matcher.
    func reloadAndSelect(ruleID: UUID) {
        reloadTable()
        guard let idx = store.userRules.firstIndex(where: { $0.id == ruleID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }
}
