import AppKit
import OpWhoLib

/// Sheet shown when the user clicks "+" in the config window. Lets them
/// pick a recent request as the starting point for a new rule (so the
/// matcher is pre-narrowed to a real-world example), or fall back to a
/// blank rule, or cancel.
///
/// UI shape: a single NSPopUpButton (newest preselected) plus a preview
/// pane that renders the selected request's salient fields. That keeps the
/// sheet compact and matches the macOS "Choose one of these" idiom — the
/// way Print/Save dialogs render preset pickers, or Mail's "Sender"
/// chooser. A 20-row table would have been visual overkill for what is
/// fundamentally a one-of-N pick.
final class AddRuleSheetController: NSWindowController {

    enum Result {
        case empty
        case fromRecent(RecentRequest)
    }

    private let recents: [RecentRequest]   // index 0 = newest
    private let onResult: (Result?) -> Void
    private let popup = NSPopUpButton()

    // Preview labels. Updated whenever the popup selection changes.
    private let triggerLabel = NSTextField(labelWithString: "")
    private let argvLabel = NSTextField(labelWithString: "")
    private let cwdLabel = NSTextField(labelWithString: "")
    private let matchedRuleLabel = NSTextField(labelWithString: "")
    private let renderedTitleLabel = NSTextField(labelWithString: "")
    private let renderedSubtitleLabel = NSTextField(labelWithString: "")
    private let useButton = NSButton(title: "Use Selected", target: nil, action: nil)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    init(recents: [RecentRequest], onResult: @escaping (Result?) -> Void) {
        self.recents = recents
        self.onResult = onResult
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Add rule from recent request"
        super.init(window: window)
        window.contentView = makeContentView()
        rebuildPopup()
        if !recents.isEmpty {
            popup.selectItem(at: 0)
            updatePreview()
        } else {
            useButton.isEnabled = false
            popup.isEnabled = false
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)

        let header = NSTextField(labelWithString: "Create a new rule from a recent 1Password request")
        header.font = NSFont.boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(header)

        let subhead = NSTextField(labelWithString:
            "The new rule's matcher starts narrowed to the picked request's process and subcommand. " +
            "You can broaden it or edit the description afterward in the detail form."
        )
        subhead.font = NSFont.systemFont(ofSize: 11)
        subhead.textColor = .secondaryLabelColor
        subhead.lineBreakMode = .byWordWrapping
        subhead.maximumNumberOfLines = 2
        subhead.preferredMaxLayoutWidth = 600
        stack.addArrangedSubview(subhead)

        stack.addArrangedSubview(makePopupRow())
        stack.addArrangedSubview(makePreviewBox())
        stack.addArrangedSubview(makeButtonBar())

        let root = NSView()
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func makePopupRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        let label = NSTextField(labelWithString: "Source request:")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        row.addArrangedSubview(label)

        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        // Wide enough that timestamp + trigger + rendered title all fit
        // without wrap, but bounded so the sheet doesn't grow unreasonably.
        popup.widthAnchor.constraint(equalToConstant: 520).isActive = true
        row.addArrangedSubview(popup)
        return row
    }

    private func makePreviewBox() -> NSView {
        let box = NSBox()
        box.title = "Selected request"
        box.titleFont = NSFont.systemFont(ofSize: 11)
        box.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 10

        // Two-column form: dim label · value. Values are selectable so the
        // user can copy interesting bits into the detail form afterward.
        configureValueLabel(triggerLabel, mono: true)
        configureValueLabel(argvLabel, mono: true)
        configureValueLabel(cwdLabel, mono: true)
        configureValueLabel(matchedRuleLabel)
        configureValueLabel(renderedTitleLabel)
        configureValueLabel(renderedSubtitleLabel)

        grid.addRow(with: [dimLabel("Trigger"), triggerLabel])
        grid.addRow(with: [dimLabel("Args"), argvLabel])
        grid.addRow(with: [dimLabel("CWD"), cwdLabel])
        grid.addRow(with: [dimLabel("Matched rule"), matchedRuleLabel])
        grid.addRow(with: [dimLabel("Title"), renderedTitleLabel])
        grid.addRow(with: [dimLabel("Subtitle"), renderedSubtitleLabel])

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
        box.widthAnchor.constraint(equalToConstant: 600).isActive = true
        return box
    }

    private func makeButtonBar() -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY

        let blank = NSButton(title: "Blank Rule", target: self, action: #selector(useBlankAction(_:)))
        bar.addArrangedSubview(blank)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction(_:)))
        cancel.keyEquivalent = "\u{1b}" // Esc
        bar.addArrangedSubview(cancel)

        useButton.target = self
        useButton.action = #selector(usePickAction(_:))
        useButton.keyEquivalent = "\r" // Return
        bar.addArrangedSubview(useButton)

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 600).isActive = true
        return bar
    }

    private func dimLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.alignment = .right
        return l
    }

    private func configureValueLabel(_ tf: NSTextField, mono: Bool = false) {
        tf.font = mono
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
        tf.isSelectable = true
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    // MARK: - Popup population

    /// Build the NSPopUpButton menu from `recents`. Each item's title is
    /// what shows when collapsed (just timestamp + trigger so the picker
    /// stays compact); the title in `attributedTitle` is the same — we
    /// don't need rich styling here. The full rendered title goes in the
    /// preview pane instead.
    private func rebuildPopup() {
        popup.removeAllItems()
        for (idx, r) in recents.enumerated() {
            let title = formatPopupItem(r)
            popup.addItem(withTitle: title)
            // Avoid duplicate-title collapse: NSPopUpButton dedupes by
            // title, so if two requests render identically (rare but
            // possible — same process, same second), only one shows. Set
            // a unique tag instead so each request keeps its slot.
            popup.lastItem?.tag = idx
            popup.lastItem?.representedObject = r.id
        }
    }

    private func formatPopupItem(_ r: RecentRequest) -> String {
        let time = Self.timeFormatter.string(from: r.timestamp)
        let process = r.chainNames.first ?? "?"
        let sub = parseSubcommand(argv: r.triggerArgv) ?? ""
        let trigger = sub.isEmpty ? process : "\(process) \(sub)"
        let renderedShort = r.title.prefix(60)
        return "\(time)  \(trigger)  —  \(renderedShort)"
    }

    private func selectedRecent() -> RecentRequest? {
        let row = popup.indexOfSelectedItem
        guard row >= 0, row < recents.count else { return nil }
        return recents[row]
    }

    // MARK: - Preview

    private func updatePreview() {
        guard let r = selectedRecent() else {
            for l in [triggerLabel, argvLabel, cwdLabel, matchedRuleLabel, renderedTitleLabel, renderedSubtitleLabel] {
                l.stringValue = ""
            }
            return
        }
        let process = r.chainNames.first ?? "?"
        let sub = parseSubcommand(argv: r.triggerArgv) ?? ""
        triggerLabel.stringValue = sub.isEmpty ? process : "\(process) \(sub)"
        argvLabel.stringValue = r.triggerArgv.isEmpty ? "—" : r.triggerArgv.joined(separator: " ")
        cwdLabel.stringValue = r.triggerCwd ?? r.cwd ?? "—"
        matchedRuleLabel.stringValue = r.matchedRuleName ?? "(no rule matched)"
        renderedTitleLabel.stringValue = r.title
        renderedSubtitleLabel.stringValue = r.subtitle ?? "—"
    }

    // MARK: - Actions

    @objc private func popupChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func usePickAction(_ sender: Any?) {
        guard let r = selectedRecent() else {
            NSSound.beep()
            return
        }
        dismiss(with: .fromRecent(r))
    }

    @objc private func useBlankAction(_ sender: Any?) {
        dismiss(with: .empty)
    }

    @objc private func cancelAction(_ sender: Any?) {
        dismiss(with: nil)
    }

    private func dismiss(with result: Result?) {
        guard let sheet = window else {
            onResult(result)
            return
        }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        onResult(result)
    }
}
