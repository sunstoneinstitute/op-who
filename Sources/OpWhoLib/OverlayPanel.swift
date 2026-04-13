import AppKit

class OverlayPanel {

    struct ProcessEntry {
        let pid: pid_t
        let chain: [ProcessNode]
        let tty: String?
        let tabTitle: String?
        let claudeSession: String?
        let terminalBundleID: String?
        let cwd: String?
    }

    private var panel: NSPanel?

    func show(entries: [ProcessEntry], near windowFrame: CGRect?) {

        let panel = makePanel()
        self.panel = panel

        let contentView = buildContentView(entries: entries)
        panel.contentView = contentView

        let fittingSize = contentView.fittingSize
        let panelSize = NSSize(
            width: max(fittingSize.width + 32, 320),
            height: fittingSize.height + 24
        )

        let origin: NSPoint
        if let frame = windowFrame, let screen = NSScreen.main {
            let screenHeight = screen.frame.height
            let axBottom = frame.origin.y + frame.size.height
            let appKitY = screenHeight - axBottom
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
        p.level = .floating
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

        // Process chain
        let chainLabel = makeChainLabel(entry.chain)
        stack.addArrangedSubview(chainLabel)

        // Working directory
        if let cwd = entry.cwd {
            let cwdLabel = makeLabel(
                cwd,
                size: 11, weight: .regular, color: .secondaryLabelColor, mono: true
            )
            cwdLabel.lineBreakMode = .byTruncatingHead
            cwdLabel.maximumNumberOfLines = 1
            cwdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(cwdLabel)
        }

        // Claude session info
        if let session = entry.claudeSession {
            let sessionLabel = makeLabel(
                "Claude: \(session)",
                size: 12, weight: .medium, color: .systemBlue, mono: false
            )
            stack.addArrangedSubview(sessionLabel)
        }

        // Tab title
        if let title = entry.tabTitle {
            let titleLabel = makeLabel(
                "Tab: \(title)",
                size: 11, weight: .regular, color: .secondaryLabelColor, mono: false
            )
            stack.addArrangedSubview(titleLabel)
        }

        // PID + TTY line
        var detail = "PID: \(entry.pid)"
        if let tty = entry.tty {
            detail += "  TTY: \(tty)"
        }
        let detailLabel = makeLabel(detail, size: 11, weight: .regular, color: .tertiaryLabelColor, mono: true)
        stack.addArrangedSubview(detailLabel)

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

    private func makeChainLabel(_ chain: [ProcessNode]) -> NSTextField {
        let label = makeLabel("", size: 13, weight: .regular, mono: true)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let attributed = NSMutableAttributedString()

        for (index, node) in chain.enumerated() {
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
                color = .labelColor
            }

            attributed.append(NSAttributedString(
                string: node.chainDisplayName,
                attributes: [.font: font, .foregroundColor: color]
            ))
        }

        label.attributedStringValue = attributed
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

        let alert = NSAlert()
        alert.messageText = "Send message to terminal?"
        alert.informativeText = "This will write a notification line to \(tty). The message does not execute any commands."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TerminalHelper.writeMessage(to: tty, message: "\n[op-who] 1Password approval requested from this session\n")
    }
}
