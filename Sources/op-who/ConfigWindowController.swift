import AppKit
import OpWhoLib

/// Tabbed configuration window. Hosts two panes side-by-side via
/// NSTabView's `.topTabsBezelBorder` style — a horizontal tab selector
/// at the top of the window with the active pane drawn in a bezeled box
/// below.
///
/// Adding a third pane later (e.g. logging, advanced) is a one-liner:
/// append another `NSTabViewItem` and the pane class that owns its
/// content.
final class ConfigWindowController: NSWindowController {

    private let generalPane: GeneralPane
    private let rulesPane: RulesPane
    private let builtInRulesPane: BuiltInRulesPane
    private let publishersPane: PublishersPane
    private let tabView = NSTabView()

    init(
        ruleStore: RequestRuleStore,
        recentStore: RecentRequestsStore,
        publisherStore: TrustedPublisherStore
    ) {
        self.generalPane = GeneralPane()
        self.rulesPane = RulesPane(store: ruleStore, recentStore: recentStore)
        self.builtInRulesPane = BuiltInRulesPane(store: ruleStore)
        self.publishersPane = PublishersPane(store: publisherStore)

        let window = ConfigWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "op-who Settings"
        window.minSize = NSSize(width: 700, height: 540)
        super.init(window: window)

        // Hand the panes the window they should present sheets on.
        // Done after super.init so `self.window` is non-nil.
        rulesPane.presenter = window
        builtInRulesPane.presenter = window
        publishersPane.presenter = window

        // "Copy as User Rule" in the Built-ins tab appends a clone to user
        // rules. Tell the User Rules pane to reload + select it (so its
        // detail form populates from the clone's matcher), then switch
        // tabs so the user lands on the new row ready to edit.
        builtInRulesPane.onCopyToUserRules = { [weak self] newRuleID in
            self?.rulesPane.reloadAndSelect(ruleID: newRuleID)
            self?.tabView.selectTabViewItem(withIdentifier: "user-rules")
        }

        window.contentView = makeContentView()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func showWindow(_ sender: Any?) {
        // Sync the General-pane startup checkbox with SMAppService on every
        // show, in case the user toggled it from System Settings while the
        // app was running.
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
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = generalPane.view
        tabView.addTabViewItem(generalTab)

        let rulesTab = NSTabViewItem(identifier: "user-rules")
        rulesTab.label = "User Rules"
        rulesTab.view = rulesPane.view
        tabView.addTabViewItem(rulesTab)

        let builtInsTab = NSTabViewItem(identifier: "built-in-rules")
        builtInsTab.label = "Built-in Rules"
        builtInsTab.view = builtInRulesPane.view
        tabView.addTabViewItem(builtInsTab)

        let publishersTab = NSTabViewItem(identifier: "publishers")
        publishersTab.label = "Trusted Publishers"
        publishersTab.view = publishersPane.view
        tabView.addTabViewItem(publishersTab)

        // Wrap the tab view in a container so we can pin it to the
        // window's content rect with a uniform margin — the bezel draws
        // against the inset edges, not flush with the title bar.
        let container = NSView()
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }
}
