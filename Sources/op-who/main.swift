import AppKit
import OpWhoLib
import ServiceManagement
import os

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var watcher: OnePasswordWatcher!
    var startupMenuItem: NSMenuItem!
    var trustPollTimer: Timer?

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
        menu.delegate = self
        let trustItem = NSMenuItem(
            title: trusted ? "Accessibility: Granted" : "Accessibility: Not Granted",
            action: nil,
            keyEquivalent: ""
        )
        trustItem.offStateImage = Self.transparentStateImage()
        menu.addItem(trustItem)
        menu.addItem(.separator())
        startupMenuItem = NSMenuItem(
            title: "Run on startup",
            action: #selector(toggleRunOnStartup(_:)),
            keyEquivalent: ""
        )
        startupMenuItem.target = self
        // Explicit checkbox glyphs in both states so the off state isn't a
        // blank gap that leaves the user guessing.
        startupMenuItem.onStateImage = NSImage(
            systemSymbolName: "checkmark.square.fill",
            accessibilityDescription: "Enabled"
        )
        startupMenuItem.offStateImage = NSImage(
            systemSymbolName: "square",
            accessibilityDescription: "Disabled"
        )
        updateStartupMenuItemState()
        menu.addItem(startupMenuItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit op-who",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        // Once any item in the menu sets an offStateImage, macOS reserves a
        // wider state column and falls back to a default "off" glyph for
        // every other .off item — which means Quit sprouts a stray empty
        // checkbox. Squash it with a transparent placeholder.
        quitItem.offStateImage = Self.transparentStateImage()
        menu.addItem(quitItem)
        statusItem.menu = menu

        watcher = OnePasswordWatcher()

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

    func menuWillOpen(_ menu: NSMenu) {
        updateStartupMenuItemState()
    }

    private func updateStartupMenuItemState() {
        startupMenuItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    /// A fully-transparent image used as an off-state placeholder for menu
    /// items that should NOT render a state glyph. Sized to roughly match
    /// the checkbox SF Symbol so column alignment stays consistent.
    private static func transparentStateImage() -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in true }
        image.isTemplate = true
        return image
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

    @objc func toggleRunOnStartup(_ sender: NSMenuItem) {
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
        updateStartupMenuItemState()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
