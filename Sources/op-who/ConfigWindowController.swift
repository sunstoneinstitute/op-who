import AppKit
import OpWhoLib

/// Single-pane Settings window. Replaces the tabbed layout with a vertical
/// stack of sections (Options, Rules) hosted inside an NSScrollView so the
/// content can grow without resizing the window. The "Run on startup"
/// toggle from the old General tab lives inline in the Options section;
/// the Rules section embeds `RulesPane`'s unified user-+-built-in table.
final class ConfigWindowController: NSWindowController {

    private let generalPane: GeneralPane
    private let rulesPane: RulesPane

    init(
        ruleStore: RequestRuleStore,
        recentStore: RecentRequestsStore
    ) {
        self.generalPane = GeneralPane()
        self.rulesPane = RulesPane(store: ruleStore, recentStore: recentStore)

        let window = ConfigWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "op-who Settings"
        window.minSize = NSSize(width: 720, height: 540)
        super.init(window: window)

        rulesPane.presenter = window

        window.contentView = makeContentView()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func showWindow(_ sender: Any?) {
        generalPane.refreshState()
        super.showWindow(sender)
    }

    /// The Configure window lives outside the app's main menu (op-who is an
    /// LSUIElement menu-bar app with no File menu), so Cmd-W isn't routed to
    /// `performClose:` automatically. Intercept it here so it closes the
    /// window the way users expect.
    private final class ConfigWindow: NSWindow {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "w" {
                performClose(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let optionsSection = makeOptionsSection()
        optionsSection.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(optionsSection)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(divider)

        let rulesView = rulesPane.view
        rulesView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(rulesView)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = stack

        // Width the inner stack to match the visible scroll-view width so
        // child views (rule table, detail form) can stretch horizontally
        // instead of clipping to their intrinsic size.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            divider.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            rulesView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            rulesView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return scroll
    }

    /// Build the Options section header + the moved-in "Run on startup"
    /// checkbox. The GeneralPane's `view` already lays out the header,
    /// subhead, and checkbox; reuse it as-is so the SMAppService wiring
    /// stays self-contained.
    private func makeOptionsSection() -> NSView {
        return generalPane.view
    }
}
