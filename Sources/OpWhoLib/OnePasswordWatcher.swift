import AppKit
import ApplicationServices

/// Watches for 1Password approval dialogs via the Accessibility API
/// and shows a process-tree overlay when one appears.
public class OnePasswordWatcher {
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var overlayPanel: OverlayPanel?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var trackedDialogElement: AXUIElement?
    private var dialogPollTimer: Timer?
    private var trackedProcessPIDs: Set<pid_t> = []

    private static let bundleIDs = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
    ]

    public init() {
        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.bundleIDs.contains(bid) else { return }
            self?.attach(to: app)
        }
        workspaceObservers.append(launchObs)

        let termObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.bundleIDs.contains(bid) else { return }
            self?.detach()
        }
        workspaceObservers.append(termObs)

        if let app = findOnePasswordApp() {
            attach(to: app)
        }
    }

    deinit {
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        detach()
    }

    // MARK: - Private

    private func findOnePasswordApp() -> NSRunningApplication? {
        for bid in Self.bundleIDs {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bid
            ).first {
                return app
            }
        }
        return nil
    }

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier

        guard ProcessTree.isRunningProcessSignedByOnePassword(pid: pid) else {
            NSLog("[op-who] Refusing to attach: 1Password app (pid \(pid)) failed code signature verification")
            return
        }

        appElement = AXUIElementCreateApplication(pid)

        var obs: AXObserver?
        let err = AXObserverCreate(pid, axCallbackFunction, &obs)
        guard err == .success, let obs = obs else {
            NSLog("[op-who] Failed to create AXObserver: \(err.rawValue)")
            return
        }
        observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(obs, appElement!, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appElement!, kAXFocusedWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )

        NSLog("[op-who] Attached to 1Password (pid \(pid))")
    }

    private func detach() {
        if let obs = observer, let el = appElement {
            AXObserverRemoveNotification(obs, el, kAXWindowCreatedNotification as CFString)
            AXObserverRemoveNotification(obs, el, kAXFocusedWindowChangedNotification as CFString)
        }
        observer = nil
        appElement = nil
        NSLog("[op-who] Detached from 1Password")
    }

    /// Check whether the AX element looks like a 1Password approval dialog.
    ///
    /// 1Password renders its UI in an Electron web view. The AX tree is often
    /// empty or incomplete when the window first appears, making content-based
    /// detection unreliable.  Instead we use a two-tier approach:
    ///
    /// 1. AXDialog subrole → always an approval dialog.
    /// 2. AXStandardWindow → accept unless the window title matches a known
    ///    non-dialog surface (vault browser, lock screen, settings, etc.).
    ///    The actual approval confirmation is deferred to `handleWindowEvent`
    ///    which checks for triggering processes.
    private func isApprovalDialog(_ element: AXUIElement) -> Bool {
        // Must be a window
        guard axStringAttribute(element, kAXRoleAttribute) == "AXWindow" else {
            return false
        }

        let subrole = axStringAttribute(element, kAXSubroleAttribute)
        if subrole == "AXDialog" {
            return true
        }

        // For standard windows, exclude known non-dialog surfaces by title.
        let title = axStringAttribute(element, kAXTitleAttribute) ?? ""
        let nonDialogPatterns = [
            "Lock Screen",
            "All Items",
            "All Accounts",
            "Settings",
            "Watchtower",
            "Developer",
        ]
        let isKnownNonDialog = nonDialogPatterns.contains { title.localizedCaseInsensitiveContains($0) }
        if isKnownNonDialog {
            return false
        }

        // Any other 1Password window (including the generic "1Password" title
        // used for SSH and CLI approval dialogs) — treat as potential approval.
        NSLog("[op-who] Potential approval window (title: \"\(title)\", subrole: \(subrole ?? "nil"))")
        return true
    }

    /// Return the string value of an AX attribute, or nil.
    private func axStringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    fileprivate func handleWindowEvent(element: AXUIElement) {
        guard isApprovalDialog(element) else { return }

        // Find trigger processes: `op` (CLI) and SSH client processes.
        // Uses a single process scan to avoid duplicate work.  Signature
        // verification of `op` binaries is deferred to chain-building time
        // so it doesn't block the initial detection.
        let triggerProcs = ProcessTree.findTriggerProcesses()
        NSLog("[op-who] Found \(triggerProcs.count) trigger process(es)")
        guard !triggerProcs.isEmpty else {
            NSLog("[op-who] No trigger processes found, skipping overlay")
            return
        }

        let windowFrame = axWindowFrame(element) ?? axWindowFrame(appElement)

        var entries: [OverlayPanel.ProcessEntry] = []
        for proc in triggerProcs {
            let result = ProcessTree.buildChain(from: proc.pid)
            // Skip processes with no meaningful context (e.g. 1Password's own
            // internal `op` helper which has no parent chain and no TTY).
            if result.chain.count <= 1 && result.tty == nil { continue }

            let tabTitle = result.tty.flatMap { tty in
                TerminalHelper.tabTitle(
                    forTTY: tty,
                    terminalBundleID: result.terminalBundleID,
                    terminalPID: result.terminalPID
                )
            }

            let claudeSession: String?
            if let claudePID = result.claudePID {
                claudeSession = ProcessTree.claudeSessionInfo(pid: claudePID)
            } else {
                claudeSession = nil
            }

            // Get CWD from the chain — the trigger process (op, ssh) often
            // has CWD of "/", so walk up to find the shell's CWD instead.
            let cwd = ProcessTree.bestCWD(chain: result.chain)
                .map(ProcessTree.tidyPath)

            entries.append(OverlayPanel.ProcessEntry(
                pid: proc.pid,
                chain: result.chain,
                tty: result.tty,
                tabTitle: tabTitle,
                claudeSession: claudeSession,
                terminalBundleID: result.terminalBundleID,
                cwd: cwd
            ))
        }

        guard !entries.isEmpty else { return }

        // Track the dialog window and triggering PIDs so we can dismiss when it closes
        trackedDialogElement = element
        trackedProcessPIDs = Set(entries.map { $0.pid })
        startDialogPolling()

        DispatchQueue.main.async { [weak self] in
            self?.showOverlay(entries: entries, near: windowFrame)
        }
    }

    private func showOverlay(entries: [OverlayPanel.ProcessEntry], near windowFrame: CGRect?) {
        if overlayPanel == nil {
            overlayPanel = OverlayPanel()
        }
        overlayPanel?.show(entries: entries, near: windowFrame)
    }

    /// Poll to detect when the 1Password dialog closes.
    /// We check both the AX element validity and whether op processes are still running.
    private func startDialogPolling() {
        dialogPollTimer?.invalidate()
        dialogPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkDialogStillOpen()
        }
    }

    private func stopDialogPolling() {
        dialogPollTimer?.invalidate()
        dialogPollTimer = nil
        trackedDialogElement = nil
        trackedProcessPIDs = []
    }

    private func checkDialogStillOpen() {
        // Check 1: is the tracked window still alive?
        var titleValue: AnyObject?
        let windowGone: Bool
        if let el = trackedDialogElement {
            let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &titleValue)
            windowGone = (err != .success)
        } else {
            windowGone = true
        }

        // Check 2: are the triggering processes still running?
        // Use kill(pid, 0) — sends no signal but returns whether the process exists.
        let procsGone = !trackedProcessPIDs.isEmpty && trackedProcessPIDs.allSatisfy { kill($0, 0) != 0 }

        if windowGone || procsGone {
            DispatchQueue.main.async { [weak self] in
                self?.overlayPanel?.dismiss()
                self?.stopDialogPolling()
            }
        }
    }

    private func axWindowFrame(_ element: AXUIElement?) -> CGRect? {
        guard let element = element else { return nil }

        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: pos, size: size)
    }
}

private func axCallbackFunction(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let watcher = Unmanaged<OnePasswordWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleWindowEvent(element: element)
}
