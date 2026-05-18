import AppKit
import ApplicationServices
import os

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
    private let recentStore: RecentRequestsStore?

    private static let bundleIDs = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
    ]

    public init(recentStore: RecentRequestsStore? = nil) {
        self.recentStore = recentStore
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
            Log.watcher.error("Refusing to attach: 1Password app (pid \(pid, privacy: .public)) failed code signature verification")
            return
        }

        appElement = AXUIElementCreateApplication(pid)

        var obs: AXObserver?
        let err = AXObserverCreate(pid, axCallbackFunction, &obs)
        guard err == .success, let obs = obs else {
            Log.watcher.error("Failed to create AXObserver: \(err.rawValue, privacy: .public)")
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

        Log.watcher.info("Attached to 1Password (pid \(pid, privacy: .public))")
    }

    private func detach() {
        if let obs = observer, let el = appElement {
            AXObserverRemoveNotification(obs, el, kAXWindowCreatedNotification as CFString)
            AXObserverRemoveNotification(obs, el, kAXFocusedWindowChangedNotification as CFString)
        }
        observer = nil
        appElement = nil
        Log.watcher.info("Detached from 1Password")
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
        Log.watcher.info("Potential approval window (title: \"\(title, privacy: .public)\", subrole: \(subrole ?? "nil", privacy: .public))")
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
        let handleStart = DispatchTime.now()
        guard isApprovalDialog(element) else { return }

        // Find trigger processes: `op` (CLI) and SSH client processes.
        // Uses a single process scan to avoid duplicate work.  Signature
        // verification of `op` binaries is deferred to chain-building time
        // so it doesn't block the initial detection.
        let triggerProcs = measure("findTriggerProcesses") { ProcessTree.findTriggerProcesses() }
        Log.watcher.info("Found \(triggerProcs.count, privacy: .public) trigger process(es)")
        for tp in triggerProcs {
            Log.watcher.info("trigger candidate pid=\(tp.pid, privacy: .public) name=\(tp.name, privacy: .public) ppid=\(tp.ppid, privacy: .public) tty=\(tp.tty ?? "<none>", privacy: .public)")
        }
        guard !triggerProcs.isEmpty else {
            Log.watcher.info("No trigger processes found, skipping overlay")
            return
        }

        let windowFrame = axWindowFrame(element) ?? axWindowFrame(appElement)

        var candidates: [TriggerCandidate] = []
        for proc in triggerProcs {
            let result = measure("buildChain[\(proc.pid)]") { ProcessTree.buildChain(from: proc.pid) }
            // Skip processes with no meaningful context (e.g. 1Password's own
            // internal `op` helper which has no parent chain and no TTY).
            if result.chain.count <= 1 && result.tty == nil {
                let chainNames = result.chain.map { $0.name }.joined(separator: ",")
                Log.watcher.info("dropped pid=\(proc.pid, privacy: .public) reason=short-chain-no-tty chain.count=\(result.chain.count, privacy: .public) chain=[\(chainNames, privacy: .public)] termBundle=\(result.terminalBundleID ?? "<none>", privacy: .public)")
                continue
            }

            // Fold an `op` helper child into its `op` parent, so the trigger
            // we render reflects the user-invoked command, not the helper.
            let foldedChain = foldOpHelper(chain: result.chain)
            let triggerNode = foldedChain.first ?? result.chain.first ?? proc
            let triggerPID = triggerNode.pid

            // `git` triggers that aren't network-capable (`git show`, `git log`,
            // etc.) can never have prompted a 1Password SSH approval, so they
            // are noise — drop them before they hit the overlay.
            let triggerArgv = measure("processArgv[\(triggerPID)]") { ProcessTree.processArgv(pid: triggerPID) }
            if triggerNode.name == "git", !isRemoteGitSubcommand(argv: triggerArgv) {
                Log.watcher.info("dropped pid=\(triggerPID, privacy: .public) reason=git-non-network argv=\(triggerArgv.joined(separator: " "), privacy: .public)")
                continue
            }

            let tabInfo: TerminalHelper.TabInfo = result.tty.map { tty in
                measure("tabInfo[\(tty)]") {
                    TerminalHelper.tabInfo(
                        forTTY: tty,
                        terminalBundleID: result.terminalBundleID,
                        terminalPID: result.terminalPID
                    )
                }
            } ?? .empty
            let tabTitle = tabInfo.name

            let claudeSession: String?
            let claudeCtx: ClaudeContext?
            if let claudePID = result.claudePID {
                claudeSession = measure("claudeSessionInfo") { ProcessTree.claudeSessionInfo(pid: claudePID) }
                if let claudeCWD = measure("claudeCWD", { ProcessTree.processCWD(pid: claudePID) }) {
                    claudeCtx = measure("claudeContext") { claudeContext(forCWD: claudeCWD) }
                } else {
                    claudeCtx = nil
                }
            } else {
                claudeSession = nil
                claudeCtx = nil
            }

            // Get CWD from the chain — the trigger process (op, ssh) often
            // has CWD of "/", so walk up to find the shell's CWD instead.
            let cwd = measure("bestCWD") { ProcessTree.bestCWD(chain: foldedChain) }
                .map(ProcessTree.tidyPath)

            // The trigger's own (untidied) CWD is needed by both plugin-update
            // detection (must live under ~/.claude/plugins/) AND the matcher
            // engine's `triggerCwdPrefix` predicate. Look it up once.
            let triggerCWD = measure("processCWD[\(triggerPID)]") { ProcessTree.processCWD(pid: triggerPID) }

            // Detect Claude Code background plugin/marketplace updates: a `git`
            // trigger whose own CWD lives under ~/.claude/plugins/. We use the
            // trigger's literal CWD (not bestCWD) because the surrounding chain
            // may have a wider CWD that escapes the plugins tree.
            let pluginUpdate: ClaudePluginUpdate? = {
                guard triggerNode.name == "git" else { return nil }
                return measure("claudePluginUpdate") {
                    claudePluginUpdate(forCWD: triggerCWD)
                }
            }()

            // For cmux, pull the workspace / tab identifiers from the trigger's
            // env block AND ask cmux itself for the user-facing workspace name
            // and tab title — those are user-renameable and the env-IDs are not.
            var cmuxWorkspaceID: String? = nil
            var cmuxTabID: String? = nil
            var cmuxSurface: CmuxSurfaceInfo? = nil
            if isCmuxBundleID(result.terminalBundleID) {
                let env = measure("processEnvironment[\(triggerPID)]") {
                    ProcessTree.processEnvironment(
                        pid: triggerPID,
                        names: ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID"]
                    )
                }
                cmuxWorkspaceID = env["CMUX_WORKSPACE_ID"]
                cmuxTabID = env["CMUX_TAB_ID"]
                Log.cmux.info("trigger pid=\(triggerPID, privacy: .public) tty=\(result.tty ?? "<nil>", privacy: .public) CMUX_WORKSPACE_ID=\(cmuxWorkspaceID ?? "<unset>", privacy: .public) CMUX_TAB_ID=\(cmuxTabID ?? "<unset>", privacy: .public)")
                if let tty = result.tty {
                    cmuxSurface = measure("cmuxSurfaceInfo[\(tty)]") { CmuxHelper.surfaceInfo(forTTY: tty) }
                } else {
                    Log.cmux.info("trigger has no TTY — skipping cmux surface lookup")
                }
            }

            let entryStartTime = measure("processStartTime") { ProcessTree.processStartTime(pid: triggerPID) }

            // Run the matcher engine once here so the same evaluation drives
            // candidate ranking, overlay rendering, ring-buffer recording,
            // and the debug log dump. The matched rule's id/name and the
            // rendered text are stored on the entry; downstream consumers
            // read those fields rather than re-evaluating the rules.
            let matchContext = MatchContext(
                chain: foldedChain,
                triggerArgv: triggerArgv,
                cwd: cwd,
                triggerCwd: triggerCWD,
                claudeSession: claudeSession,
                pluginUpdate: pluginUpdate,
                terminalBundleID: result.terminalBundleID
            )
            let summary = makeRequestSummary(
                chain: foldedChain,
                triggerArgv: triggerArgv,
                tabTitle: tabTitle,
                claudeSession: claudeSession,
                terminalBundleID: result.terminalBundleID,
                cwd: cwd,
                triggerCwd: triggerCWD,
                pluginUpdate: pluginUpdate
            )
            let matchResult = RequestRuleEngine.evaluate(rules: OpWhoConfig.rules, context: matchContext)

            let entry = OverlayPanel.ProcessEntry(
                pid: triggerPID,
                chain: foldedChain,
                triggerArgv: triggerArgv,
                tty: result.tty,
                tabTitle: tabTitle,
                tabShortcut: tabInfo.shortcut,
                claudeSession: claudeSession,
                claudeContext: claudeCtx,
                terminalBundleID: result.terminalBundleID,
                terminalPID: result.terminalPID,
                cwd: cwd,
                triggerCwd: triggerCWD,
                cmuxWorkspaceID: cmuxWorkspaceID,
                cmuxTabID: cmuxTabID,
                cmuxSurface: cmuxSurface,
                startTime: entryStartTime,
                pluginUpdate: pluginUpdate,
                summary: summary,
                matchedRuleID: matchResult?.rule.id,
                matchedRuleName: matchResult?.rule.name,
                matchedBuiltInID: matchResult?.rule.builtInID
            )

            candidates.append(TriggerCandidate(
                entry: entry,
                kind: summary.kind,
                startTime: ProcessTree.processStartTime(pid: triggerPID)
            ))
        }

        guard let chosen = measure("selectBestCandidate", { selectBestCandidate(candidates) }) else {
            Log.watcher.info("No surviving trigger candidates after filter+fold")
            return
        }
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - handleStart.uptimeNanoseconds) / 1_000_000.0
        Log.timing.info("handleWindowEvent total \(String(format: "%.1fms", totalMs), privacy: .public) (candidates=\(candidates.count, privacy: .public))")

        // Suppress redundant re-shows. 1Password's Electron-rendered dialog
        // fires multiple AXWindowCreated / AXFocusedWindowChanged events for
        // a single logical approval (empty shell → re-render → real title
        // resolved 5s later), and rebuilding the overlay on each event makes
        // it appear to flash/relocate or — when timed against the user
        // approving — look like "a second popup just appeared". If we're
        // already polling for the same trigger PID, just update the tracked
        // AX element and skip the re-render.
        if dialogPollTimer != nil && trackedProcessPIDs.contains(chosen.entry.pid) {
            Log.watcher.debug("re-detected same approval (pid \(chosen.entry.pid, privacy: .public)) — refresh only")
            trackedDialogElement = element
            return
        }

        let displayedEntries = [chosen.entry]

        // Track *all* surviving candidate PIDs, not just the displayed one.
        // git/ssh workflows routinely spawn sibling processes (control-master
        // auth helper + session, fetch-pack + push-pack, etc.) and the one we
        // pick for display may exit seconds before the one actually waiting
        // on the user's approval. Dismiss only when every viable trigger has
        // exited — that's the moment the dialog can plausibly be done.
        trackedDialogElement = element
        trackedProcessPIDs = Set(candidates.map { $0.entry.pid })
        Log.watcher.debug("tracking pids=\(self.trackedProcessPIDs.sorted(), privacy: .public) displayed=\(chosen.entry.pid, privacy: .public)")
        startDialogPolling()

        Log.watcher.debug("dialog-shown entries=\(jsonDump(entries: displayedEntries), privacy: .public) candidates=\(candidates.count, privacy: .public)")

        if let store = recentStore {
            let recent = RecentRequest(
                chainNames: chosen.entry.chain.map { $0.name },
                triggerArgv: chosen.entry.triggerArgv,
                cwd: chosen.entry.cwd,
                triggerCwd: chosen.entry.triggerCwd,
                binaryVerified: chosen.entry.chain.first?.isVerifiedOnePasswordCLI ?? false,
                claudeSession: chosen.entry.claudeSession,
                terminalBundleID: chosen.entry.terminalBundleID,
                tabTitle: chosen.entry.tabTitle,
                pluginRemoteURL: chosen.entry.pluginUpdate?.remoteURL,
                title: chosen.entry.summary.title,
                subtitle: chosen.entry.summary.subtitle,
                kindRaw: chosen.entry.summary.kind.rawValue,
                isWarning: chosen.entry.summary.isWarning,
                matchedRuleID: chosen.entry.matchedRuleID,
                matchedRuleName: chosen.entry.matchedRuleName,
                matchedBuiltInID: chosen.entry.matchedBuiltInID
            )
            store.record(recent)
        }

        DispatchQueue.main.async { [weak self] in
            self?.showOverlay(entries: displayedEntries, near: windowFrame)
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
        // 1Password's Electron web view can invalidate the AX element reference
        // when it re-renders asynchronously.  When the cached element looks gone,
        // re-scan 1Password's windows before concluding the dialog closed.
        var titleValue: AnyObject?
        var windowGone: Bool
        var initialAXErr: AXError = .success
        if let el = trackedDialogElement {
            let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &titleValue)
            initialAXErr = err
            windowGone = (err != .success)
        } else {
            windowGone = true
        }

        var rescanOutcome: String = "n/a"
        if windowGone, let app = appElement {
            // The cached element is stale — check if an approval dialog still exists.
            if let freshElement = findApprovalDialog(in: app) {
                trackedDialogElement = freshElement
                windowGone = false
                rescanOutcome = "found-fresh-dialog"
            } else {
                rescanOutcome = "no-dialog-found"
            }
        }

        // Check 2: are the triggering processes still running?
        // Use kill(pid, 0) — sends no signal but returns whether the process exists.
        let livePIDs = trackedProcessPIDs.filter { kill($0, 0) == 0 }
        let procsGone = !trackedProcessPIDs.isEmpty && livePIDs.isEmpty

        Log.watcher.debug("poll-tick windowGone=\(windowGone, privacy: .public) (initialAXErr=\(initialAXErr.rawValue, privacy: .public), rescan=\(rescanOutcome, privacy: .public)) tracked=\(self.trackedProcessPIDs.sorted(), privacy: .public) live=\(livePIDs.sorted(), privacy: .public)")

        // Dismiss only when *both* signals agree the dialog is over.
        //
        // - Process-alive overrides AX-gone: Electron-rendered dialogs
        //   intermittently invalidate their AX element while remaining visible,
        //   so a live trigger process means the overlay must stay up.
        // - AX-alive overrides process-gone: SSH siblings (control-master
        //   helper + session, fetch-pack + push-pack, etc.) sometimes exit
        //   while the approval prompt remains on screen waiting on the user.
        //   If AX still reports the window as valid, trust that — the overlay
        //   should outlive the trigger processes in that case.
        guard procsGone && windowGone else { return }

        Log.watcher.info("Dismissing overlay: windowGone=\(windowGone, privacy: .public) (initialAXErr=\(initialAXErr.rawValue, privacy: .public), rescan=\(rescanOutcome, privacy: .public)) procsGone=true tracked=\(self.trackedProcessPIDs.sorted(), privacy: .public) live=\(livePIDs.sorted(), privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.overlayPanel?.dismiss()
            self?.stopDialogPolling()
        }
    }

    /// Enumerate 1Password's windows and return the first that looks like an approval dialog.
    private func findApprovalDialog(in app: AXUIElement) -> AXUIElement? {
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }
        return windows.first { isApprovalDialog($0) }
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

/// Serialize an array of ProcessEntry as a single-line JSON string for the
/// unified log. Returns "[]" on any encoding error rather than throwing —
/// debug logs must never crash a release build.
func jsonDump(entries: [OverlayPanel.ProcessEntry]) -> String {
    let payload: [[String: Any]] = entries.map { entry in
        var dict: [String: Any] = [
            "pid": entry.pid,
            "chain": entry.chain.map { node -> [String: Any] in
                var n: [String: Any] = [
                    "pid": node.pid,
                    "ppid": node.ppid,
                    "name": node.name,
                ]
                if let tty = node.tty { n["tty"] = tty }
                if let exe = node.executablePath { n["exe"] = exe }
                if node.name == "op" {
                    n["verifiedOnePasswordCLI"] = node.isVerifiedOnePasswordCLI
                }
                return n
            },
        ]
        if let tty = entry.tty { dict["tty"] = tty }
        if let title = entry.tabTitle { dict["tabTitle"] = title }
        if let session = entry.claudeSession { dict["claudeSession"] = session }
        if let bid = entry.terminalBundleID { dict["terminalBundleID"] = bid }
        if let tpid = entry.terminalPID { dict["terminalPID"] = tpid }
        if let cwd = entry.cwd { dict["cwd"] = cwd }
        if !entry.triggerArgv.isEmpty { dict["triggerArgv"] = entry.triggerArgv }
        if let ctx = entry.claudeContext {
            var c: [String: Any] = ["sessionID": ctx.sessionID]
            if let p = ctx.lastUserPrompt { c["lastUserPrompt"] = p }
            if let cmd = ctx.lastRelevantCommand { c["lastRelevantCommand"] = cmd }
            dict["claudeContext"] = c
        }
        if let pu = entry.pluginUpdate {
            dict["pluginUpdate"] = ["remoteURL": pu.remoteURL]
        }
        if let ws = entry.cmuxWorkspaceID { dict["cmuxWorkspaceID"] = ws }
        if let tab = entry.cmuxTabID { dict["cmuxTabID"] = tab }
        if let s = entry.cmuxSurface {
            dict["cmuxSurface"] = [
                "workspaceRef": s.workspaceRef,
                "workspaceTitle": s.workspaceTitle,
                "surfaceRef": s.surfaceRef,
                "surfaceTitle": s.surfaceTitle,
                "tty": s.tty,
            ]
        }

        let summary = entry.summary
        var s: [String: Any] = [
            "kind": summary.kind.rawValue,
            "title": summary.title,
            "isWarning": summary.isWarning,
        ]
        if let sub = summary.subtitle { s["subtitle"] = sub }
        if let rule = entry.matchedRuleName { s["matchedRule"] = rule }
        dict["summary"] = s
        return dict
    }

    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
          let str = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return str
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
