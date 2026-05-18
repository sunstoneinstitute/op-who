import AppKit

class OverlayPanel {

    struct ProcessEntry {
        let pid: pid_t
        let chain: [ProcessNode]
        let triggerArgv: [String]
        let tty: String?
        let tabTitle: String?
        /// Optional keyboard-shortcut hint for jumping to the source tab
        /// (e.g. "⌘1", "⌘9", "window 2 ⌘3"). Set for iTerm, nil for other
        /// terminals where the concept doesn't apply.
        let tabShortcut: String?
        let claudeSession: String?
        let claudeContext: ClaudeContext?
        let terminalBundleID: String?
        let terminalPID: pid_t?
        let cwd: String?
        /// Trigger process's own (untidied) CWD. Stored for the ring buffer
        /// so we can later replay rules whose `triggerCwdPrefix` matters.
        let triggerCwd: String?
        let cmuxWorkspaceID: String?
        let cmuxTabID: String?
        let cmuxSurface: CmuxSurfaceInfo?
        /// Start time of the trigger process — used for the elapsed-time column.
        let startTime: Date?
        /// Set when the trigger is a `git` operation Claude Code initiated
        /// in the background to refresh a plugin/marketplace repo.
        let pluginUpdate: ClaudePluginUpdate?
        /// Pre-computed summary (title/subtitle/kind/isWarning) for this
        /// entry. Computed once by the watcher so the overlay and log don't
        /// re-evaluate the rule engine.
        let summary: RequestSummary
        /// Identity of the rule that produced `summary`. Used to render
        /// the matched-rule name in the recent-requests ring buffer.
        let matchedRuleID: UUID?
        let matchedRuleName: String?
        /// Stable, release-spanning identifier of the matched rule when
        /// the match was a built-in; nil for user-authored rules. Stored
        /// alongside `matchedRuleID` so `RecentRequest` can look up the
        /// matched built-in after a restart (UUIDs are regenerated each
        /// process run).
        let matchedBuiltInID: String?
    }

    private var panel: NSPanel?

    /// Trailing time labels updated every second by `elapsedTimer`.
    private var elapsedLabels: [ElapsedLabel] = []
    private var elapsedTimer: Timer?

    func show(entries: [ProcessEntry], near windowFrame: CGRect?) {

        let panel = makePanel()
        self.panel = panel

        // Build content (and as a side effect, register elapsed labels).
        elapsedLabels.removeAll()
        let contentView = buildContentView(entries: entries)
        panel.contentView = contentView
        refreshElapsed()
        startElapsedTimer()

        let fittingSize = contentView.fittingSize
        let panelSize = NSSize(
            width: max(fittingSize.width + 32, 320),
            height: fittingSize.height + 24
        )

        let origin: NSPoint
        if let frame = windowFrame {
            // AX uses CG global coordinates (origin = top-left of primary display, y grows down).
            // AppKit uses bottom-left of primary display, y grows up. The flip MUST use the
            // primary display's height — not NSScreen.main, which tracks keyboard focus and
            // can be a non-primary screen on multi-monitor setups.
            let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                ?? NSScreen.screens.first
                ?? NSScreen.main)?.frame.height ?? 0
            let axBottom = frame.origin.y + frame.size.height
            let appKitY = primaryHeight - axBottom
            origin = NSPoint(
                x: frame.origin.x + (frame.width - panelSize.width) / 2,
                y: appKitY + frame.height + 8
            )
        } else if let screen = NSScreen.main {
            origin = NSPoint(
                x: screen.frame.midX - panelSize.width / 2,
                y: screen.frame.midY + 100
            )
        } else {
            origin = NSPoint(x: 200, y: 400)
        }

        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedLabels.removeAll()
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshElapsed()
        }
        // Common run-loop mode so the tick fires even while menu tracking, modal
        // sessions, or other panels are foregrounded.
        RunLoop.main.add(t, forMode: .common)
        elapsedTimer = t
    }

    private func refreshElapsed() {
        let now = Date()
        for entry in elapsedLabels {
            let secs = now.timeIntervalSince(entry.startTime)
            entry.label.stringValue = formatElapsed(secs)
            entry.label.textColor = elapsedColor(secs)
        }
    }

    // MARK: - UI Construction

    private func makePanel() -> NSPanel {
        if let existing = panel { return existing }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = NSColor.windowBackgroundColor
        p.hasShadow = true

        return p
    }

    private func buildContentView(entries: [ProcessEntry]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let header = makeLabel("op-who", size: 11, weight: .medium, color: .secondaryLabelColor)
        stack.addArrangedSubview(header)

        for entry in entries {
            stack.addArrangedSubview(buildEntryView(entry))
        }

        return stack
    }

    private func buildEntryView(_ entry: ProcessEntry) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        let kind = entry.summary.kind

        // Three structured lead lines.
        let terminalRow = makeTerminalRow(entry)
        stack.addArrangedSubview(terminalRow)
        // Pin the terminal row to the stack's full width so its trailing
        // shortcuts/timer cluster can right-align. Other rows keep their
        // natural intrinsic width (default .leading alignment).
        terminalRow.translatesAutoresizingMaskIntoConstraints = false
        terminalRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        terminalRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        stack.addArrangedSubview(makeDriverRow(entry))
        stack.addArrangedSubview(makeOperationRow(entry, kind: kind))

        // Claude-derived "asked" context (the natural-language prompt).
        if let prompt = entry.claudeContext?.lastUserPrompt {
            let label = makeLabel(
                "“\(prompt)”",
                size: 11, weight: .regular, color: .secondaryLabelColor
            )
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.cell?.wraps = true
            // Cap the prompt's layout width at ~40% of screen width so a long
            // prompt wraps instead of stretching the overlay. Other rows are
            // single-line truncate-tail, so the prompt is the only line that
            // can blow up the panel width.
            label.preferredMaxLayoutWidth = promptMaxLayoutWidth()
            stack.addArrangedSubview(label)
        }

        // Technical detail block: hidden by default. Toggled by a small
        // disclosure button so a curious user can drop down chain/pid/argv.
        let detailsContainer = NSStackView()
        detailsContainer.orientation = .vertical
        detailsContainer.alignment = .leading
        detailsContainer.spacing = 2
        detailsContainer.isHidden = true
        detailsContainer.addArrangedSubview(makeChainDetailLabel(entry))
        for line in detailLines(for: entry) {
            detailsContainer.addArrangedSubview(makeDimDetailLabel(line))
        }

        let toggle = DetailsToggleButton(detailContainer: detailsContainer)
        toggle.title = "▸ details"
        toggle.isBordered = false
        toggle.font = NSFont.systemFont(ofSize: 11)
        toggle.contentTintColor = .tertiaryLabelColor
        toggle.target = self
        toggle.action = #selector(toggleDetails(_:))
        stack.addArrangedSubview(toggle)
        stack.addArrangedSubview(detailsContainer)

        // Action buttons
        if let tty = entry.tty {
            let buttonStack = NSStackView()
            buttonStack.orientation = .horizontal
            buttonStack.spacing = 8

            let showBtn = NSButton(title: "Show Tab", target: nil, action: nil)
            showBtn.bezelStyle = .recessed
            showBtn.font = NSFont.systemFont(ofSize: 11)
            showBtn.target = self
            showBtn.action = #selector(showTerminalTab(_:))
            showBtn.cell?.representedObject = [tty, entry.terminalBundleID as Any]
            buttonStack.addArrangedSubview(showBtn)

            let msgBtn = NSButton(title: "Send Message", target: nil, action: nil)
            msgBtn.bezelStyle = .recessed
            msgBtn.font = NSFont.systemFont(ofSize: 11)
            msgBtn.target = self
            msgBtn.action = #selector(sendTTYMessage(_:))
            msgBtn.cell?.representedObject = tty
            buttonStack.addArrangedSubview(msgBtn)

            stack.addArrangedSubview(buttonStack)
        }

        return stack
    }

    // MARK: - Lead rows (icon + text)

    /// Row 1: terminal app icon + workspace/tab name + trailing elapsed time.
    ///
    /// Prefer cmux's live tree (workspace title + surface title) when we have
    /// it — those names are user-renameable and the env vars don't update.
    /// Fall back to NSAccessibility-derived tabTitle for non-cmux terminals.
    private func makeTerminalRow(_ entry: ProcessEntry) -> NSView {
        let bundleID = entry.terminalBundleID
        let termName = humanTerminalName(bundleID: bundleID) ?? "Unknown terminal"
        let parts = Self.terminalRowParts(entry: entry, termName: termName)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        // Leading icon (or 16pt spacer for alignment).
        let leadingDim: CGFloat = 16
        if let icon = appIcon(bundleID: bundleID) {
            let iv = NSImageView()
            iv.image = icon
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: leadingDim).isActive = true
            iv.heightAnchor.constraint(equalToConstant: leadingDim).isActive = true
            row.addArrangedSubview(iv)
        } else {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: leadingDim).isActive = true
            spacer.heightAnchor.constraint(equalToConstant: leadingDim).isActive = true
            row.addArrangedSubview(spacer)
        }

        // Main title label: user-visible title (bright) + terminal qualifier (dim).
        // Workspace/tab name leads because it's what the user actually recognizes;
        // the terminal name trails as a subdued qualifier. Stretches to fill
        // remaining horizontal space so trailing shortcuts and timer can right-align.
        let label = makeLabel("", size: 13, weight: .semibold, color: .labelColor)
        let mainFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let dim = NSColor.secondaryLabelColor
        let bright = NSColor.labelColor
        let attr = NSMutableAttributedString()
        if !parts.title.isEmpty {
            attr.append(NSAttributedString(
                string: parts.title,
                attributes: [.font: mainFont, .foregroundColor: bright]
            ))
        }
        attr.append(NSAttributedString(
            string: parts.qualifier,
            attributes: [.font: mainFont, .foregroundColor: dim]
        ))
        label.attributedStringValue = attr
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // Low hugging = absorbs extra width (pushes trailing items right).
        // Low compression resistance = truncates first when space is tight.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        // Trailing shortcuts label: cmux's ⌘N/⌃M (from suffix) and/or iTerm's
        // tab navigation hint (from shortcut). Right-aligned at content size.
        let shortcutsText = composeShortcuts(suffix: parts.suffix, shortcut: parts.shortcut)
        var shortcutsLabel: NSTextField? = nil
        if !shortcutsText.isEmpty {
            let sl = makeLabel(
                shortcutsText,
                size: 12, weight: .medium, color: dim, mono: true
            )
            sl.alignment = .right
            sl.setContentHuggingPriority(.required, for: .horizontal)
            sl.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(sl)
            shortcutsLabel = sl
        }

        // Trailing elapsed-time label, only if we know the start time.
        if let start = entry.startTime {
            let timeLabel = makeLabel(
                formatElapsed(0),
                size: 12, weight: .medium,
                color: elapsedColor(0),
                mono: true
            )
            timeLabel.alignment = .right
            // Reserve a fixed slot so growing values ("5s" → "10s" → "1m0s")
            // fill the slot from the right rather than pushing the rest of
            // the row around. 56pt comfortably fits "59m59s" in 12pt mono.
            timeLabel.translatesAutoresizingMaskIntoConstraints = false
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            timeLabel.setContentHuggingPriority(.required, for: .horizontal)
            timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            // Add visual breathing room between the shortcuts cluster and
            // the timer so they read as separate concerns.
            if let sl = shortcutsLabel {
                row.setCustomSpacing(16, after: sl)
            }
            row.addArrangedSubview(timeLabel)
            elapsedLabels.append(ElapsedLabel(label: timeLabel, startTime: start))
        }

        return row
    }

    /// Decomposition of row 1 for styled rendering. `title` is rendered first
    /// in a brighter color so the user-visible workspace/tab name leads;
    /// `qualifier` trails in a dim color as a terminal-app annotation.
    struct TerminalRowParts: Equatable {
        /// User-visible title (e.g. "trusthere", "1. zsh — work"), rendered
        /// first in the bright color. Empty when no title is available, in
        /// which case `qualifier` is the bare terminal name.
        let title: String
        /// Dim qualifier rendered after the title. When `title` is non-empty
        /// this is something like " · cmux" or " · iTerm" (separator + term
        /// name). When `title` is empty this is just the bare terminal name
        /// with no leading separator.
        let qualifier: String
        /// Trailing keyboard-shortcut text (cmux's " ⌘N ⌃M"). Goes into the
        /// separate trailing shortcuts label, not the main title attributed
        /// string. May be empty.
        let suffix: String
        /// Legacy iTerm shortcut hint (e.g. "⌘3", "window 2 ⌘1"). nil when
        /// not applicable. Also goes into the trailing shortcuts label.
        let shortcut: String?

        /// Backward-compatible flat-string composition used by tests/logging.
        var main: String { title + qualifier + suffix }
    }

    /// Build the parts of row 1.
    static func terminalRowParts(entry: ProcessEntry, termName: String) -> TerminalRowParts {
        if let s = entry.cmuxSurface {
            // For cmux we deliberately skip the surface (tab) title: it's
            // typically a duplicate of the workspace title (the CWD), and
            // the user can navigate to the right tab with the ⌃N shortcut.
            let wsTitle = s.displayWorkspaceTitle
            let wsKey = s.workspaceIndex > 0 ? " ⌘\(s.workspaceIndex)" : ""
            // ⌃N is only useful when the user has more than one tab to switch
            // between — otherwise ⌃1 is trivial. Keep showing it when the
            // tab count is unknown (0) so stale state doesn't drop info.
            let showTabKey = s.tabIndex > 0 && s.workspaceTabCount != 1
            let tabKey = showTabKey ? " ⌃\(s.tabIndex)" : ""

            if !wsTitle.isEmpty {
                return TerminalRowParts(
                    title: wsTitle,
                    qualifier: " · \(termName)",
                    suffix: "\(wsKey)\(tabKey)",
                    shortcut: nil
                )
            }
            if !wsKey.isEmpty || !tabKey.isEmpty {
                return TerminalRowParts(
                    title: "", qualifier: termName, suffix: "\(wsKey)\(tabKey)", shortcut: nil
                )
            }
            return TerminalRowParts(title: "", qualifier: termName, suffix: "", shortcut: nil)
        }
        // For cmux without surface info, AX window title is unreliable
        // (returns "Item-0" placeholders rather than the visible workspace
        // name). Show only the terminal name.
        if isCmuxBundleID(entry.terminalBundleID) {
            return TerminalRowParts(title: "", qualifier: termName, suffix: "", shortcut: nil)
        }
        let title = entry.tabTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        let shortcut = entry.tabShortcut?.trimmingCharacters(in: .whitespaces)
        let shortcutOrNil = (shortcut?.isEmpty ?? true) ? nil : shortcut
        if !title.isEmpty {
            return TerminalRowParts(
                title: title, qualifier: " · \(termName)", suffix: "", shortcut: shortcutOrNil
            )
        }
        return TerminalRowParts(title: "", qualifier: termName, suffix: "", shortcut: shortcutOrNil)
    }

    /// Flat-string composition of row 1. Kept for callers (tests, logging)
    /// that don't need the styled rendering — the UI uses `terminalRowParts`.
    static func terminalRowText(entry: ProcessEntry, termName: String) -> String {
        let p = terminalRowParts(entry: entry, termName: termName)
        if let s = p.shortcut { return "\(p.main) \(s)" }
        return p.main
    }

    /// Row 2: the user-recognizable process driving the trigger.
    /// "Claude Code", a known editor/IDE, or the nearest shell name.
    /// Shows the app icon when the driver maps to a known macOS bundle.
    private func makeDriverRow(_ entry: ProcessEntry) -> NSView {
        let info = driverDescription(
            chain: entry.chain, claudeSession: entry.claudeSession
        )
        let color: NSColor
        let weight: NSFont.Weight
        switch info.kind {
        // Distinct from the operation row's colors (which use systemBlue for
        // .ssh and systemGreen for op CLI), so the "who" and "what" lines
        // read as visually separate.
        case .claude: color = .systemPurple; weight = .semibold
        case .editor: color = .systemTeal;   weight = .semibold
        case .shell:  color = .labelColor;   weight = .medium
        case .other:  color = .labelColor;   weight = .medium
        }
        // Append the requesting process's cwd in a subdued color. Skips "/"
        // (which means we never found a meaningful directory in the chain).
        let cwdSuffix: String? = {
            guard let c = entry.cwd, c != "/", !c.isEmpty else { return nil }
            return c
        }()
        return makeIconRow(
            icon: appIcon(bundleID: info.bundleID),
            text: info.text,
            size: 12, weight: weight, color: color,
            dimSuffix: cwdSuffix
        )
    }

    /// Row 3: the requested operation — `op item list`, `op read op://X/Y`,
    /// `git fetch origin`, etc. Color-coded by kind.
    private func makeOperationRow(_ entry: ProcessEntry, kind: RequestKind) -> NSView {
        if let update = entry.pluginUpdate {
            return makeIconRow(
                icon: nil,
                text: "plugin update check from \(update.remoteURL)",
                size: 12, weight: .medium, color: .secondaryLabelColor,
                mono: true
            )
        }
        let text = operationDisplay(argv: entry.triggerArgv, chain: entry.chain, cwd: entry.cwd)
        return makeIconRow(
            icon: nil,
            text: text,
            size: 12, weight: .medium, color: operationColor(kind: kind),
            mono: true
        )
    }

    /// Build a horizontal row: small icon (or 16pt spacer) on the left,
    /// a single-line label on the right. When `dimSuffix` is non-empty the
    /// label is rendered as an attributed string with the suffix tinted in
    /// `secondaryLabelColor` — used to append context like the requesting
    /// process's cwd after the driver name.
    private func makeIconRow(
        icon: NSImage?,
        text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        mono: Bool = false,
        dimSuffix: String? = nil
    ) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let leadingDim: CGFloat = 16
        if let icon = icon {
            let iv = NSImageView()
            iv.image = icon
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: leadingDim).isActive = true
            iv.heightAnchor.constraint(equalToConstant: leadingDim).isActive = true
            row.addArrangedSubview(iv)
        } else {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: leadingDim).isActive = true
            spacer.heightAnchor.constraint(equalToConstant: leadingDim).isActive = true
            row.addArrangedSubview(spacer)
        }

        let label = makeLabel(text, size: size, weight: weight, color: color, mono: mono)
        if let suffix = dimSuffix, !suffix.isEmpty {
            let font = mono
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            let attr = NSMutableAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color]
            )
            attr.append(NSAttributedString(
                string: " \(suffix)",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            ))
            label.attributedStringValue = attr
        }
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        return row
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor = .labelColor,
        mono: Bool = false
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = true
        return label
    }

    /// Build the small, dim detail rows displayed under the process chain:
    /// `pid · tty`, `cwd ~/...`, and `argv …`.  Each row is only added when
    /// the underlying data is present.
    private func detailLines(for entry: ProcessEntry) -> [String] {
        var lines: [String] = []
        var ids = "pid \(entry.pid)"
        if let tty = entry.tty { ids += " · \(tty)" }
        lines.append(ids)

        if let cwd = entry.cwd {
            lines.append("cwd: \(cwd)")
        }
        if !entry.triggerArgv.isEmpty {
            lines.append("argv: \(entry.triggerArgv.joined(separator: " "))")
        }
        if let ws = entry.cmuxWorkspaceID {
            var line = "cmux: workspace=\(ws)"
            if let tab = entry.cmuxTabID { line += " · tab=\(tab)" }
            lines.append(line)
        }
        return lines
    }

    /// Small grey monospaced label for an auxiliary detail row.
    private func makeDimDetailLabel(_ text: String) -> NSTextField {
        let label = makeLabel(text, size: 11, weight: .regular, color: .secondaryLabelColor, mono: true)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// One-line tertiary detail combining the process chain alone.
    /// Kept small and dim so the human-readable summary leads the entry.
    private func makeChainDetailLabel(_ entry: ProcessEntry) -> NSTextField {
        let label = makeLabel("", size: 11, weight: .regular, mono: true)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attributed = NSMutableAttributedString()

        for (index, node) in entry.chain.enumerated() {
            if index > 0 {
                attributed.append(NSAttributedString(
                    string: " \u{2192} ",
                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
                ))
            }
            let color: NSColor
            if node.name == "op" {
                color = node.isVerifiedOnePasswordCLI ? .systemGreen : .systemOrange
            } else {
                color = .secondaryLabelColor
            }
            attributed.append(NSAttributedString(
                string: node.chainDisplayName,
                attributes: [.font: font, .foregroundColor: color]
            ))
        }

        label.attributedStringValue = attributed
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    // MARK: - Actions

    @objc private func showTerminalTab(_ sender: NSButton) {
        guard let info = sender.cell?.representedObject as? [Any],
              let tty = info[0] as? String else { return }
        let bid = info[1] as? String
        TerminalHelper.activateTab(forTTY: tty, terminalBundleID: bid)
    }

    @objc private func sendTTYMessage(_ sender: NSButton) {
        guard let tty = sender.cell?.representedObject as? String else { return }
        TerminalHelper.writeMessage(to: tty, message: "\n[op-who] 1Password approval requested from this session\n")
    }

    // MARK: - Color & icon

    /// Color-code the operation line by request kind:
    ///   - verified op:   green
    ///   - unverified op: orange (warning)
    ///   - ssh / git:     blue
    ///   - unknown:       default label
    private func operationColor(kind: RequestKind) -> NSColor {
        switch kind {
        case .onePasswordCLI: return .systemGreen
        case .unverifiedOp:   return .systemOrange
        case .ssh:            return .systemBlue
        case .unknown:        return .labelColor
        }
    }

    /// Compose the shortcuts label content from `parts.suffix` (cmux's
    /// " ⌘N ⌃M") and `parts.shortcut` (iTerm's "⌘3" or "window 2 ⌘1").
    /// Both forms are joined with a space and stripped of leading whitespace.
    private func composeShortcuts(suffix: String, shortcut: String?) -> String {
        var s = suffix.trimmingCharacters(in: .whitespaces)
        if let extra = shortcut, !extra.isEmpty {
            if !s.isEmpty { s += " " }
            s += extra
        }
        return s
    }

    /// Target max width for the wrapping prompt label: 40% of the main
    /// screen, minus the panel's outer padding (~32) and the stack's edge
    /// insets (~32). Floored to a usable minimum so tiny screens don't make
    /// the popup unreadable.
    private func promptMaxLayoutWidth() -> CGFloat {
        let screenW = NSScreen.main?.frame.width ?? 1440
        return max(300, screenW * 0.4 - 64)
    }

    /// Fetch the terminal app's icon via NSWorkspace, cached per bundle ID.
    private func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID = bundleID else { return nil }
        if let cached = Self.iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        Self.iconCache[bundleID] = image
        return image
    }

    private static var iconCache: [String: NSImage] = [:]

    // MARK: - Disclosure toggle

    @objc private func toggleDetails(_ sender: DetailsToggleButton) {
        guard let container = sender.detailContainer else { return }
        let willShow = container.isHidden
        container.isHidden = !willShow
        sender.title = willShow ? "▾ details" : "▸ details"
        resizePanelToFit()
    }

    /// Re-fit the panel after expanding/collapsing a details block. We anchor
    /// the panel's top edge so the lead rows stay put visually and the panel
    /// grows downward as new rows appear.
    private func resizePanelToFit() {
        guard let panel = panel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let newWidth = max(fitting.width + 32, 320)
        let newHeight = fitting.height + 24
        let currentFrame = panel.frame
        // Anchor top: top-Y stays constant, height changes, origin.y adjusts.
        let topY = currentFrame.origin.y + currentFrame.height
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: topY - newHeight,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }
}

/// NSButton subclass with an associated detail container — used by the
/// "▸ details" disclosure toggle so the action handler can find what to
/// show/hide without maintaining a side table.
private class DetailsToggleButton: NSButton {
    weak var detailContainer: NSStackView?
    init(detailContainer: NSStackView) {
        self.detailContainer = detailContainer
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}

/// One trailing time label for a single entry. The OverlayPanel ticks them
/// all together once per second.
private struct ElapsedLabel {
    let label: NSTextField
    let startTime: Date
}

/// "49s" for under a minute, "1m12s" otherwise. Floors to whole seconds.
func formatElapsed(_ secs: TimeInterval) -> String {
    let total = max(0, Int(secs))
    if total < 60 { return "\(total)s" }
    let m = total / 60
    let s = total % 60
    return "\(m)m\(s)s"
}

/// 0-9s: secondary label. 10-29s: warning orange. 30s+: error red.
func elapsedColor(_ secs: TimeInterval) -> NSColor {
    if secs < 10 { return .secondaryLabelColor }
    if secs < 30 { return .systemOrange }
    return .systemRed
}
