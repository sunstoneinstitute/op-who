import AppKit
import OpWhoLib

/// Unified rules section inside the Settings window. Master/detail editor
/// for every rule the engine evaluates — user-authored rules at the top
/// (they run first via `RequestRuleStore.allRules`), followed by the
/// built-ins shipped with op-who. Each row has an Enabled checkbox:
///   - User rules: flips `rule.enabled` on the stored rule.
///   - Built-ins: toggles `disabledBuiltInIDs` membership.
/// Built-in rows render with a read-only detail form; users clone them
/// (via the + menu's "Clone Selected Rule" item) to customize.
///
/// `presenter` is a weak reference to the window that should own any
/// modal sheet this pane opens. The host sets it after the window exists.
final class RulesPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let store: RequestRuleStore
    private let recentStore: RecentRequestsStore
    weak var presenter: NSWindow?

    private let tableView = NSTableView()
    private var selectedRuleID: UUID? = nil
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
    private let commentView = NSTextView()
    private let commentScroll = NSScrollView()
    private let replacesActorCheckbox = NSButton(checkboxWithTitle: "Replaces actor (full title)", target: nil, action: nil)
    private let isWarningCheckbox = NSButton(checkboxWithTitle: "Render as warning", target: nil, action: nil)
    private let kindPopup = NSPopUpButton()
    private let detailBox = NSBox()
    private let builtInNotice = NSTextField(
        labelWithString: "Built-in rule — read-only. Use “+ → Clone Selected Rule” to make an editable copy."
    )

    /// Editable detail controls, gathered once so we can flip them all to
    /// disabled (read-only) when a built-in is selected.
    private var editableControls: [NSControl] {
        [
            nameField, processNameField, subcommandField, argvContainsAllField,
            triggerCwdPrefixField, regexPatternField, templateField,
            binaryVerifiedPopup, pluginUpdatePopup, regexSourcePopup,
            kindPopup, replacesActorCheckbox, isWarningCheckbox,
        ]
    }

    private(set) lazy var view: NSView = makeContentView()

    init(store: RequestRuleStore, recentStore: RecentRequestsStore) {
        self.store = store
        self.recentStore = recentStore
        super.init()
        _ = view // force-build so initial selection takes effect
        reloadTable()
        // Select first row (which will be the first user rule if any,
        // otherwise the first built-in).
        let rules = store.allRules
        if !rules.isEmpty {
            selectedRuleID = rules[0].id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        loadDetailFromSelection()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let container = NSView()

        let header = NSTextField(labelWithString: "Rules")
        header.font = NSFont.boldSystemFont(ofSize: 13)

        let subhead = NSTextField(labelWithString:
            "User-authored rules at the top run first; built-ins follow. " +
            "Each rule's matcher is evaluated against the trigger process, its argv, and its cwd; first enabled match wins. " +
            "Toggle the Enabled checkbox to skip a rule without removing it."
        )
        subhead.font = NSFont.systemFont(ofSize: 11)
        subhead.textColor = .secondaryLabelColor
        subhead.lineBreakMode = .byWordWrapping
        subhead.maximumNumberOfLines = 3

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

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            subhead.topAnchor.constraint(equalTo: header.bottomAnchor, constant: spacing),
            tableScroll.topAnchor.constraint(equalTo: subhead.bottomAnchor, constant: spacing),
            buttonBar.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: spacing),
            detail.topAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: spacing),
            detail.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
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
        enabledCol.title = ""
        enabledCol.width = 24
        enabledCol.minWidth = 24
        enabledCol.maxWidth = 30
        tableView.addTableColumn(enabledCol)

        let originCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("origin"))
        originCol.title = ""
        originCol.width = 70
        originCol.minWidth = 60
        originCol.maxWidth = 80
        tableView.addTableColumn(originCol)

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

        // "+ with options": a plain NSButton that pops up a menu on
        // click. Tried NSPopUpButton in pull-down mode first but it
        // renders the first item's title (or "NSMenuItem" if empty)
        // alongside the chevron, which clutters a button that should
        // just read as "+". popUp(positioning:at:in:) gives the same
        // affordance with a cleaner face.
        let plusButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add rule")!,
            target: self,
            action: #selector(showAddMenu(_:))
        )
        plusButton.bezelStyle = .smallSquare
        plusButton.setContentHuggingPriority(.required, for: .horizontal)
        bar.addArrangedSubview(plusButton)

        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove selected user rule")!,
            target: self,
            action: #selector(removeSelected(_:))
        )
        removeButton.bezelStyle = .smallSquare
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        bar.addArrangedSubview(removeButton)

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

        let reset = NSButton(title: "Remove All User Rules", target: self, action: #selector(resetAction(_:)))
        bar.addArrangedSubview(reset)

        return bar
    }

    private func makeDetailForm() -> NSView {
        detailBox.title = "Selected rule"
        detailBox.titleFont = NSFont.systemFont(ofSize: 11)

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

        commentView.delegate = self
        commentView.isRichText = false
        commentView.font = NSFont.systemFont(ofSize: 12)
        commentView.textContainerInset = NSSize(width: 4, height: 4)
        commentScroll.borderType = .bezelBorder
        commentScroll.hasVerticalScroller = true
        commentScroll.documentView = commentView
        commentScroll.translatesAutoresizingMaskIntoConstraints = false
        commentScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        commentScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true

        builtInNotice.font = NSFont.systemFont(ofSize: 11)
        builtInNotice.textColor = .secondaryLabelColor
        builtInNotice.isHidden = true

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
        grid.addRow(with: [label("Comment"), commentScroll])
        grid.addRow(with: [label("Kind"), kindPopup])
        grid.addRow(with: [NSView(), replacesActorCheckbox])
        grid.addRow(with: [NSView(), isWarningCheckbox])
        grid.addRow(with: [NSView(), builtInNotice])

        grid.column(at: 0).xPlacement = .leading
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
        detailBox.contentView = content
        return detailBox
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

    func numberOfRows(in tableView: NSTableView) -> Int { store.allRules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let rules = store.allRules
        guard row < rules.count else { return nil }
        let rule = rules[row]

        switch col.identifier.rawValue {
        case "enabled":
            let id = NSUserInterfaceItemIdentifier("cell_enabled")
            let cell: EnabledCheckboxCell
            if let existing = tableView.makeView(withIdentifier: id, owner: self) as? EnabledCheckboxCell {
                cell = existing
            } else {
                cell = EnabledCheckboxCell()
                cell.identifier = id
            }
            cell.configure(ruleID: rule.id, enabled: rule.enabled) { [weak self] ruleID, newValue in
                self?.store.setRuleEnabled(id: ruleID, enabled: newValue)
                self?.reloadTable()
            }
            return cell
        default:
            let id = NSUserInterfaceItemIdentifier("cell_\(col.identifier.rawValue)")
            let cell: NSTableCellView = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCellView(id: id)
            switch col.identifier.rawValue {
            case "origin":
                cell.textField?.stringValue = (rule.builtInID == nil) ? "User" : "Built-in"
                cell.textField?.font = NSFont.systemFont(ofSize: 11)
                cell.textField?.textColor = (rule.builtInID == nil) ? .labelColor : .secondaryLabelColor
            case "name":
                cell.textField?.stringValue = rule.name
                cell.textField?.textColor = rule.enabled ? .labelColor : .disabledControlTextColor
            case "when":
                cell.textField?.stringValue = rule.matcher.displaySummary
                cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                cell.textField?.textColor = rule.enabled ? .labelColor : .disabledControlTextColor
            case "then":
                cell.textField?.stringValue = rule.template
                cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                cell.textField?.textColor = rule.enabled ? .labelColor : .disabledControlTextColor
            default: break
            }
            return cell
        }
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
        let row = tableView.selectedRow
        let rules = store.allRules
        if row >= 0 && row < rules.count {
            selectedRuleID = rules[row].id
        } else {
            selectedRuleID = nil
        }
        loadDetailFromSelection()
    }

    // MARK: - Actions

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let blank = NSMenuItem(title: "Blank Rule", action: #selector(addBlank(_:)), keyEquivalent: "")
        blank.target = self
        menu.addItem(blank)
        let fromRecent = NSMenuItem(title: "From Recent Request…", action: #selector(addFromRecent(_:)), keyEquivalent: "")
        fromRecent.target = self
        fromRecent.isEnabled = !recentStore.requests.isEmpty
        menu.addItem(fromRecent)
        let clone = NSMenuItem(title: "Clone Selected Rule", action: #selector(addClone(_:)), keyEquivalent: "")
        clone.target = self
        clone.isEnabled = (selectedRuleID != nil)
        menu.addItem(clone)
        // Show the menu just below the button, matching the way
        // pull-down toolbar pickers anchor in Finder / Mail.
        let origin = NSPoint(x: 0, y: sender.bounds.maxY + 2)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func addBlank(_ sender: Any?) {
        insertUserRule(emptyTemplateRule())
    }

    @objc private func addFromRecent(_ sender: Any?) {
        let recents = recentStore.requests.reversed()
        guard !recents.isEmpty else {
            insertUserRule(emptyTemplateRule())
            return
        }
        let sheet = AddRuleSheetController(recents: Array(recents)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .none: break
            case .some(.empty): self.insertUserRule(self.emptyTemplateRule())
            case .some(.fromRecent(let recent)):
                self.insertUserRule(self.ruleFromRecent(recent))
            }
            self.addSheet = nil
        }
        addSheet = sheet
        if let host = presenter, let sheetWindow = sheet.window {
            host.beginSheet(sheetWindow, completionHandler: nil)
        }
    }

    @objc private func addClone(_ sender: Any?) {
        guard let id = selectedRuleID,
              let source = store.allRules.first(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        // Strip the built-in identity from the clone so it lives as a
        // standalone user rule. Fresh UUID, "Copy of …" name, enabled by
        // default regardless of the source's enabled state.
        let clone = RequestRule(
            id: UUID(),
            name: "Copy of \(source.name)",
            matcher: source.matcher,
            template: source.template,
            replacesActor: source.replacesActor,
            kind: source.kind,
            isWarning: source.isWarning,
            comment: source.comment,
            enabled: true,
            builtInID: nil
        )
        insertUserRule(clone)
    }

    @objc private func removeSelected(_ sender: Any?) {
        guard let id = selectedRuleID,
              let idx = store.userRules.firstIndex(where: { $0.id == id }) else {
            // Built-in selected — removing isn't allowed; flash with a beep.
            NSSound.beep()
            return
        }
        var rules = store.userRules
        rules.remove(at: idx)
        store.setUserRules(rules)
        reloadTable()
        let allRules = store.allRules
        if !allRules.isEmpty {
            let nextIdx = min(idx, allRules.count - 1)
            selectedRuleID = allRules[nextIdx].id
            tableView.selectRowIndexes(IndexSet(integer: nextIdx), byExtendingSelection: false)
        } else {
            selectedRuleID = nil
        }
        loadDetailFromSelection()
    }

    @objc private func moveAction(_ sender: NSSegmentedControl) {
        let delta: Int
        switch sender.selectedSegment {
        case 0: delta = -1
        case 1: delta = +1
        default: return
        }
        moveSelected(by: delta)
    }

    @objc private func resetAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remove all user rules?"
        alert.informativeText = "Your user-authored rules will be deleted. Built-in rules remain unchanged — toggle their checkboxes in the table to enable or disable them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearUserRules()
        selectedRuleID = nil
        reloadTable()
        loadDetailFromSelection()
    }

    @objc private func detailChanged(_ sender: Any?) {
        commitDetail()
    }

    private func commitDetail() {
        guard let id = selectedRuleID,
              let idx = store.userRules.firstIndex(where: { $0.id == id }) else {
            return
        }
        var rule = store.userRules[idx]
        rule.name = nameField.stringValue
        rule.matcher = currentMatcherFromForm()
        rule.template = templateField.stringValue
        rule.comment = commentView.string.isEmpty ? nil : commentView.string
        rule.replacesActor = (replacesActorCheckbox.state == .on)
        rule.isWarning = (isWarningCheckbox.state == .on)
        if let raw = kindPopup.titleOfSelectedItem,
           let kind = RequestKind(rawValue: raw) {
            rule.kind = kind
        }
        var rules = store.userRules
        rules[idx] = rule
        store.setUserRules(rules)
        // Reload only the affected row, keeping selection.
        let allRules = store.allRules
        if let visIdx = allRules.firstIndex(where: { $0.id == id }) {
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: visIdx),
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }
    }

    // MARK: - Mutations

    private func insertUserRule(_ rule: RequestRule) {
        var rules = store.userRules
        // Insert after the selected user rule, if any; otherwise append
        // (which still places it ahead of all built-ins, since user rules
        // come first in `allRules`).
        let target: Int = {
            if let id = selectedRuleID,
               let idx = rules.firstIndex(where: { $0.id == id }) {
                return idx + 1
            }
            return rules.count
        }()
        rules.insert(rule, at: target)
        store.setUserRules(rules)
        reloadTable()
        selectedRuleID = rule.id
        if let visIdx = store.allRules.firstIndex(where: { $0.id == rule.id }) {
            tableView.selectRowIndexes(IndexSet(integer: visIdx), byExtendingSelection: false)
            tableView.scrollRowToVisible(visIdx)
        }
        loadDetailFromSelection()
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
        // recent request. Built-in rule UUIDs regenerate every process
        // run, so a persisted `matchedRuleID` from a previous session
        // won't match any built-in here — look the built-in up by its
        // stable `builtInID` first, then fall back to UUID for matches
        // that happened within this process run (e.g. against user rules
        // recorded earlier in the same session).
        let inherited: RequestRule? = {
            if let bid = recent.matchedBuiltInID,
               let rule = RequestRule.builtIn(id: bid) {
                return rule
            }
            if let id = recent.matchedRuleID,
               let rule = store.allRules.first(where: { $0.id == id }) {
                return rule
            }
            return nil
        }()
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

    private func moveSelected(by delta: Int) {
        guard let id = selectedRuleID,
              let idx = store.userRules.firstIndex(where: { $0.id == id }) else {
            // Reordering only applies to user rules (built-ins ship in a
            // fixed order). Beep so the user knows nothing happened.
            NSSound.beep()
            return
        }
        let target = idx + delta
        guard target >= 0, target < store.userRules.count, target != idx else { return }
        var rules = store.userRules
        let rule = rules.remove(at: idx)
        rules.insert(rule, at: target)
        store.setUserRules(rules)
        reloadTable()
        if let visIdx = store.allRules.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: visIdx), byExtendingSelection: false)
        }
    }

    // MARK: - Detail form ↔ rule

    private func loadDetailFromSelection() {
        guard let id = selectedRuleID,
              let rule = store.allRules.first(where: { $0.id == id }) else {
            clearDetail()
            setEditable(true)
            return
        }
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
        commentView.string = rule.comment ?? ""
        replacesActorCheckbox.state = rule.replacesActor ? .on : .off
        isWarningCheckbox.state = rule.isWarning ? .on : .off
        kindPopup.selectItem(withTitle: rule.kind.rawValue)

        let isBuiltIn = (rule.builtInID != nil)
        setEditable(!isBuiltIn)
        builtInNotice.isHidden = !isBuiltIn
        detailBox.title = isBuiltIn
            ? "Selected rule (built-in — read only)"
            : "Selected rule"
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
        commentView.string = ""
        replacesActorCheckbox.state = .off
        isWarningCheckbox.state = .off
        kindPopup.selectItem(at: 3)
        builtInNotice.isHidden = true
        detailBox.title = "Selected rule"
    }

    private func setEditable(_ editable: Bool) {
        for control in editableControls {
            control.isEnabled = editable
        }
        commentView.isEditable = editable
        commentView.isSelectable = true // selectable even when read-only so users can copy
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
        // Keep the visual selection aligned with `selectedRuleID` after
        // mutations that shift indices (e.g. adding a user rule above
        // built-ins).
        if let id = selectedRuleID,
           let idx = store.allRules.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }
}

// MARK: - NSTextViewDelegate

extension RulesPane: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        commitDetail()
    }
}

// MARK: - Enabled checkbox cell

/// Custom table cell that hosts a checkbox bound to a rule's `enabled`
/// flag. The cell stashes the rule's UUID so the action can route the
/// new state back to the store without depending on row indices, which
/// may shift between the time the cell is configured and the time the
/// checkbox fires (the store mutates and the table reloads).
private final class EnabledCheckboxCell: NSTableCellView {

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var ruleID: UUID?
    private var onToggle: ((UUID, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(ruleID: UUID, enabled: Bool, onToggle: @escaping (UUID, Bool) -> Void) {
        self.ruleID = ruleID
        self.onToggle = onToggle
        checkbox.state = enabled ? .on : .off
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let id = ruleID else { return }
        onToggle?(id, sender.state == .on)
    }
}
