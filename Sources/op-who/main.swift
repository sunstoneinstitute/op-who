import AppKit
import OpWhoLib
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var watcher: OnePasswordWatcher!
    var trustPollTimer: Timer?

    // Stores own on-disk state. The recent-requests store is passed to
    // the watcher so each detection drops an entry into the ring buffer.
    let ruleStore = RequestRuleStore()
    let recentStore = RecentRequestsStore()
    let publisherStore = TrustedPublisherStore()
    var configController: ConfigWindowController?

    override init() {
        super.init()
        // Wire stores to the globals BEFORE any detection happens, then
        // seed the globals with the loaded values.
        ruleStore.onRulesChanged = { OpWhoConfig.rules = $0 }
        publisherStore.onPublishersChanged = { OpWhoConfig.trustedTeamIDs = $0.map { $0.teamID } }
        OpWhoConfig.rules = ruleStore.allRules
        OpWhoConfig.trustedTeamIDs = publisherStore.publishers.map { $0.teamID }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.imagePosition = .imageOnly
            button.title = ""
        }

        let menu = NSMenu()
        // No item in this menu uses a state image, so suppress the column
        // macOS would otherwise reserve on the left.
        menu.showsStateColumn = false
        let trustItem = NSMenuItem(
            title: trusted ? "Accessibility: Granted" : "Accessibility: Not Granted",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(trustItem)
        menu.addItem(.separator())
        let configItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openConfigure(_:)),
            keyEquivalent: ","
        )
        configItem.target = self
        menu.addItem(configItem)
        let quitItem = NSMenuItem(
            title: "Quit op-who",
            // Route through our own selector instead of NSApplication.terminate(_:)
            // — macOS auto-decorates menu items bound directly to terminate:
            // with an `xmark.square` glyph that ignores `showsStateColumn`.
            action: #selector(quitAction(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        watcher = OnePasswordWatcher(recentStore: recentStore)

        if !trusted {
            startTrustPolling()
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
                op-who needs Accessibility access to detect 1Password approval dialogs.

                Go to System Settings > Privacy & Security > Accessibility and enable op-who. It will detect the change and restart itself automatically — no need to reopen.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Poll for Accessibility trust while we're running unprivileged.
    /// AXObserver registration is gated by trust at the moment of registration;
    /// once we've launched without trust, the watcher's observer is permanently
    /// inert until the process restarts. So when trust flips on, relaunch.
    private func startTrustPolling() {
        trustPollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, AXIsProcessTrusted() else { return }
            self.trustPollTimer?.invalidate()
            self.trustPollTimer = nil
            self.relaunchAfterTrustGranted()
        }
        // .common so the timer fires even while alerts/modal sessions are up.
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    private func relaunchAfterTrustGranted() {
        let bundlePath = Bundle.main.bundlePath
        Log.app.info("Accessibility granted; relaunching from \(bundlePath, privacy: .public)")

        // Spawn a detached shell that waits for us to exit, then reopens the bundle.
        let escaped = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; /usr/bin/open '\(escaped)'"]
        do {
            try task.run()
        } catch {
            Log.app.error("Failed to spawn relaunch helper: \(String(describing: error), privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Draw the menu-bar template icon: a filled disk with the inner ring
    /// and the "?" glyph punched out as transparent cutouts. Mirrors the
    /// 1Password app icon's silhouette (so the visual relationship reads at
    /// a glance) but with "?" in place of "1". Marked `isTemplate = true`
    /// so macOS tints for the menu bar's light/dark mode.
    private static func menuBarIcon() -> NSImage {
        // Menu bar slot is ~22pt tall; 18pt leaves a hair of breathing room.
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // 1. Fill the disk.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()

            guard let gc = NSGraphicsContext.current else { return true }
            gc.saveGraphicsState()
            // .destinationOut: subsequent drawing clears alpha wherever it
            // would have painted, regardless of color. That turns strokes
            // and glyphs into transparent cutouts in the disk.
            gc.compositingOperation = .destinationOut

            // 2. Concentric ring cutout, set in slightly from the disk edge.
            let ringInset = size * 0.09
            let ringPath = NSBezierPath(ovalIn: rect.insetBy(dx: ringInset, dy: ringInset))
            ringPath.lineWidth = max(1, size * 0.06)
            NSColor.black.setStroke()
            ringPath.stroke()

            // 3. "?" cutout, centered. Heavy weight so the glyph reads at
            // 18pt; size tuned to fill the ring without crowding it.
            let font = NSFont.systemFont(ofSize: size * 0.62, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
            ]
            let glyph = NSAttributedString(string: "?", attributes: attrs)
            let glyphSize = glyph.size()
            let glyphOrigin = NSPoint(
                x: rect.midX - glyphSize.width / 2,
                y: rect.midY - glyphSize.height / 2
            )
            glyph.draw(at: glyphOrigin)

            gc.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc func quitAction(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    @objc func openConfigure(_ sender: Any?) {
        if configController == nil {
            configController = ConfigWindowController(
                ruleStore: ruleStore,
                recentStore: recentStore,
                publisherStore: publisherStore
            )
        }
        // LSUIElement apps don't get activated by clicking a menu item;
        // poke the activation policy briefly so the config window comes
        // to the front and accepts keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        configController?.showWindow(nil)
        configController?.window?.makeKeyAndOrderFront(nil)
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
