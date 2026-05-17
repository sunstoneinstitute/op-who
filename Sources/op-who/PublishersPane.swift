import AppKit
import OpWhoLib

/// Trusted Publishers tab inside the Configure window. Master/detail editor
/// for the list of Apple Team IDs whose signed binaries op-who treats as
/// verified. See RulesPane for the cousin pane.
final class PublishersPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let store: TrustedPublisherStore
    weak var presenter: NSWindow?

    private let tableView = NSTableView()
    private var selectedIndex: Int? { tableView.selectedRow >= 0 ? tableView.selectedRow : nil }

    private let nameField = NSTextField()
    private let teamIDField = NSTextField()

    private(set) lazy var view: NSView = makeContentView()

    init(store: TrustedPublisherStore) {
        self.store = store
        super.init()
        _ = view
        reloadTable()
        if !store.publishers.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let container = NSView()

        let header = NSTextField(labelWithString: "Trusted publishers for binary verification")
        header.font = NSFont.boldSystemFont(ofSize: 13)

        let subhead = NSTextField(labelWithString:
            "A trigger binary whose code-signing certificate matches any of these Apple Team IDs " +
            "is treated as verified — matcher rules with “Binary verified: verified” will accept it. " +
            "The 1Password app is also attached only when its running signature matches one of these."
        )
        subhead.font = NSFont.systemFont(ofSize: 11)
        subhead.textColor = .secondaryLabelColor
        subhead.lineBreakMode = .byWordWrapping
        subhead.maximumNumberOfLines = 3

        let scroll = makeTableScroll()
        let bar = makeButtonBar()
        let detail = makeDetailForm()

        for v in [header, subhead, scroll, bar, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        let pad: CGFloat = 16
        let spacing: CGFloat = 10
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
            subhead.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            subhead.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
            detail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            subhead.topAnchor.constraint(equalTo: header.bottomAnchor, constant: spacing),
            scroll.topAnchor.constraint(equalTo: subhead.bottomAnchor, constant: spacing),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: spacing),
            detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: spacing),
            detail.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
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

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Publisher"
        nameCol.width = 260
        tableView.addTableColumn(nameCol)

        let teamCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("teamID"))
        teamCol.title = "Team ID"
        teamCol.width = 260
        tableView.addTableColumn(teamCol)

        scroll.documentView = tableView
        return scroll
    }

    private func makeButtonBar() -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY

        let addRemove = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "plus", accessibilityDescription: "Add publisher")!,
                NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove selected publisher")!,
            ],
            trackingMode: .momentary,
            target: self,
            action: #selector(addRemoveAction(_:))
        )
        addRemove.segmentStyle = .smallSquare
        bar.addArrangedSubview(addRemove)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetAction(_:)))
        bar.addArrangedSubview(reset)

        return bar
    }

    private func makeDetailForm() -> NSView {
        let box = NSBox()
        box.title = "Selected publisher"
        box.titleFont = NSFont.systemFont(ofSize: 11)

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 8

        configureField(nameField, placeholder: "Display name (e.g. 1Password)")
        configureField(teamIDField, placeholder: "Apple Team ID (e.g. 2BUA8C4S2C)")

        grid.addRow(with: [label("Name"), nameField])
        grid.addRow(with: [label("Team ID"), teamIDField])

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        box.contentView = content
        return box
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(detailChanged(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.alignment = .right
        return l
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { store.publishers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell_\(col.identifier.rawValue)")
        let cell: NSTableCellView = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCellView(id: id)
        let p = store.publishers[row]
        switch col.identifier.rawValue {
        case "name":
            cell.textField?.stringValue = p.name
        case "teamID":
            cell.textField?.stringValue = p.teamID
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
        case 0: addNew()
        case 1: removeSelected()
        default: break
        }
    }

    @objc private func resetAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset trusted publishers?"
        alert.informativeText = "This restores the built-in list (1Password). Any custom publishers will be removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.resetToDefaults()
        reloadTable()
        if !store.publishers.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func detailChanged(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        var p = store.publishers[index]
        p.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        p.teamID = teamIDField.stringValue.trimmingCharacters(in: .whitespaces)
        var list = store.publishers
        list[index] = p
        store.replace(list)
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    private func addNew() {
        let new = TrustedPublisher(name: "New publisher", teamID: "")
        var list = store.publishers
        let target = (selectedIndex.map { $0 + 1 }) ?? list.count
        list.insert(new, at: target)
        store.replace(list)
        reloadTable()
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        presenter?.makeFirstResponder(nameField)
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }

        // Removing the last publisher disables AX-attach to 1Password, so
        // op-who stops working entirely. Confirm — and tell them how to
        // recover via Reset to Default.
        if store.publishers.count == 1 {
            let alert = NSAlert()
            alert.messageText = "Remove the last trusted publisher?"
            alert.informativeText = "With no trusted publishers, op-who will refuse to attach to 1Password and stop detecting approval dialogs. Use Reset to Default to recover."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        var list = store.publishers
        list.remove(at: index)
        store.replace(list)
        reloadTable()
        if !list.isEmpty {
            let next = min(index, list.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        } else {
            clearDetail()
        }
    }

    // MARK: - Detail form ↔ row

    private func loadDetailFromSelection() {
        guard let index = selectedIndex else {
            clearDetail()
            return
        }
        let p = store.publishers[index]
        nameField.stringValue = p.name
        teamIDField.stringValue = p.teamID
    }

    private func clearDetail() {
        nameField.stringValue = ""
        teamIDField.stringValue = ""
    }

    private func reloadTable() {
        tableView.reloadData()
    }
}
