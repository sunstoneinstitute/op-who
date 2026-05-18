import AppKit
import ServiceManagement

/// Options section inside the Settings window. Currently holds just the
/// "Run on startup" toggle that used to live in the status-bar menu —
/// kept in its own type so future global toggles can sit alongside it
/// without reshaping the surrounding layout.
final class GeneralPane: NSObject {

    private let startupCheckbox = NSButton(
        checkboxWithTitle: "Run op-who on startup",
        target: nil,
        action: nil
    )

    private(set) lazy var view: NSView = makeContentView()

    override init() {
        super.init()
        _ = view
        startupCheckbox.target = self
        startupCheckbox.action = #selector(toggleStartup(_:))
        refreshState()
    }

    /// Re-read the SMAppService status. Called from the window-controller
    /// just before the window appears, so a change made via System Settings
    /// while op-who was running shows up the next time the user opens
    /// Settings.
    func refreshState() {
        startupCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func makeContentView() -> NSView {
        let container = NSView()

        let header = NSTextField(labelWithString: "Options")
        header.font = NSFont.boldSystemFont(ofSize: 13)

        let subhead = NSTextField(labelWithString:
            "Global behavior settings for op-who."
        )
        subhead.font = NSFont.systemFont(ofSize: 11)
        subhead.textColor = .secondaryLabelColor

        for v in [header, subhead, startupCheckbox] {
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
            startupCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            subhead.topAnchor.constraint(equalTo: header.bottomAnchor, constant: spacing),
            startupCheckbox.topAnchor.constraint(equalTo: subhead.bottomAnchor, constant: spacing * 2),
            // Bottom anchor closes the container's intrinsic content size.
            // Without it, the surrounding NSStackView reads height 0 and
            // packs the next section right on top of this one.
            startupCheckbox.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    @objc private func toggleStartup(_ sender: NSButton) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change startup setting"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshState()
    }
}
