import Foundation

/// Classifies a 1Password approval trigger into a category understandable
/// without knowing the process model.
public enum RequestKind: String, Codable, Equatable {
    /// Trusted `op` binary signed by 1Password.
    case onePasswordCLI
    /// `op` binary that failed signature verification — surface as a warning.
    case unverifiedOp
    /// SSH-family request (ssh, scp, sftp, rsync, or git invoking ssh).
    case ssh
    /// Trigger we couldn't classify (chain empty or unfamiliar leader).
    case unknown
}

/// Human-readable summary of why a 1Password approval dialog appeared.
public struct RequestSummary: Equatable {
    public let kind: RequestKind
    /// One-sentence plain-English description: who is asking and for what.
    public let title: String
    /// Optional secondary line — terminal app and working directory.
    public let subtitle: String?
    /// True when something looks off and the user should pay attention.
    public let isWarning: Bool

    public init(kind: RequestKind, title: String, subtitle: String?, isWarning: Bool) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.isWarning = isWarning
    }
}

/// Build a RequestSummary from the structured fields collected at detection.
///
/// `chain` is the trigger-first parent chain (chain[0] is the trigger).
/// `triggerArgv` is the full argv of `chain[0]`, used to extract op subcommands,
/// git subcommands, and similar diagnostic detail. Pass `[]` if unavailable.
///
/// `rules` selects which ordered ruleset to run. nil uses the live
/// `OpWhoConfig.rules` (the user's stored configuration); tests pass an
/// explicit list when they want a hermetic check.
public func makeRequestSummary(
    chain: [ProcessNode],
    triggerArgv: [String] = [],
    tabTitle: String?,
    claudeSession: String?,
    terminalBundleID: String?,
    cwd: String?,
    triggerCwd: String? = nil,
    pluginUpdate: ClaudePluginUpdate? = nil,
    rules: [RequestRule]? = nil
) -> RequestSummary {
    let activeRules = rules ?? OpWhoConfig.rules
    let context = MatchContext(
        chain: chain,
        triggerArgv: triggerArgv,
        cwd: cwd,
        triggerCwd: triggerCwd,
        claudeSession: claudeSession,
        pluginUpdate: pluginUpdate,
        terminalBundleID: terminalBundleID
    )

    // Engine produces both the matched rule (semantic kind, warning state)
    // and the rendered text. nil only happens with an empty ruleset; the
    // built-in defaults always end in a catch-all, so guard with a
    // hardcoded fallback to keep callers tolerant of broken user configs.
    let result = RequestRuleEngine.evaluate(rules: activeRules, context: context)

    let kind: RequestKind
    let action: String
    let replacesActor: Bool
    let ruleWarning: Bool
    if let result = result {
        kind = result.rule.kind
        action = result.rendered
        replacesActor = result.rule.replacesActor
        ruleWarning = result.rule.isWarning
    } else {
        kind = .unknown
        action = "triggered 1Password"
        replacesActor = false
        ruleWarning = true
    }

    let title: String
    let subtitle: String?
    if replacesActor {
        // Full-title override (e.g. Claude plugin update housekeeping). The
        // subtitle still carries terminal/cwd so provenance reads at a glance.
        var subtitleParts: [String] = []
        if let term = humanTerminalName(bundleID: terminalBundleID) {
            subtitleParts.append(term)
        }
        if let cwd = cwd { subtitleParts.append(cwd) }
        title = action
        subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
    } else {
        let actor = describeActor(
            chain: chain,
            tabTitle: tabTitle,
            claudeSession: claudeSession,
            terminalBundleID: terminalBundleID
        )
        title = "\(actor) \(action)"

        var subtitleParts: [String] = []
        if let claudeSession = claudeSession,
           !actor.contains("’\(claudeSession)’") {
            // Subtitle echoes the session only if the title didn't already name it.
            subtitleParts.append("session: \(claudeSession)")
        }
        if let term = humanTerminalName(bundleID: terminalBundleID),
           !actor.contains(term) {
            subtitleParts.append(term)
        }
        if let cwd = cwd {
            subtitleParts.append(cwd)
        }
        subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
    }

    return RequestSummary(
        kind: kind,
        title: title,
        subtitle: subtitle,
        isWarning: ruleWarning
    )
}

/// Human-readable name for a known terminal bundle ID.
public func humanTerminalName(bundleID: String?) -> String? {
    guard let id = bundleID else { return nil }
    switch id {
    case "com.apple.Terminal": return "Terminal"
    case "com.googlecode.iterm2": return "iTerm"
    case "com.mitchellh.ghostty": return "Ghostty"
    case "dev.warp.Warp-Stable", "dev.warp.Warp": return "Warp"
    case "io.cmux", "com.cmux.cmux", "com.cmuxterm.app": return "cmux"
    default: return id
    }
}

public func isCmuxBundleID(_ id: String?) -> Bool {
    id == "io.cmux" || id == "com.cmux.cmux" || id == "com.cmuxterm.app"
}

/// Known shell process names — used to pick a driver when there's no Claude.
let shellProcessNames: Set<String> = ["bash", "zsh", "fish", "sh", "tcsh", "ksh", "dash"]

public enum DriverKind: Equatable {
    /// Claude Code is in the chain.
    case claude
    /// An editor or IDE (VS Code, Cursor, Emacs, vim, JetBrains, …) is in the chain.
    case editor
    /// Nothing more specific than a shell.
    case shell
    /// Some other parent process — best-effort fallback.
    case other
}

public struct DriverInfo: Equatable {
    public let text: String
    public let kind: DriverKind
    /// If non-nil, the macOS app bundle ID to fetch an icon for.
    /// Terminal-only editors (vim, neovim, helix, emacs CLI, …) carry no
    /// bundle ID — there's no GUI app to harvest an icon from.
    public let bundleID: String?
}

/// Map of process-name (as it appears in `ps`, max 15 chars truncated) →
/// (display name, optional bundle ID for icon lookup).
/// Process names from kinfo_proc truncate at MAXCOMLEN so patterns here
/// are kept short; the matcher uses prefix matching for helper variants.
let knownEditors: [(processName: String, display: String, bundleID: String?)] = [
    ("Code Helper", "VS Code", "com.microsoft.VSCode"),
    ("Code", "VS Code", "com.microsoft.VSCode"),
    ("Code - Insider", "VS Code Insiders", "com.microsoft.VSCodeInsiders"),
    ("Cursor Helper", "Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Cursor", "Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Zed Helper", "Zed", "dev.zed.Zed"),
    ("Zed", "Zed", "dev.zed.Zed"),
    ("emacs", "Emacs", nil),
    ("Emacs", "Emacs", "org.gnu.Emacs"),
    ("vim", "vim", nil),
    ("nvim", "Neovim", nil),
    ("mvim", "MacVim", "org.vim.MacVim"),
    ("hx", "Helix", nil),
    ("helix", "Helix", nil),
    ("nano", "nano", nil),
    ("micro", "micro", nil),
    ("idea", "IntelliJ IDEA", "com.jetbrains.intellij"),
    ("pycharm", "PyCharm", "com.jetbrains.pycharm"),
    ("webstorm", "WebStorm", "com.jetbrains.WebStorm"),
    ("rubymine", "RubyMine", "com.jetbrains.rubymine"),
    ("goland", "GoLand", "com.jetbrains.goland"),
    ("clion", "CLion", "com.jetbrains.CLion"),
    ("rider", "Rider", "com.jetbrains.rider"),
    ("phpstorm", "PhpStorm", "com.jetbrains.PhpStorm"),
    ("datagrip", "DataGrip", "com.jetbrains.datagrip"),
    ("sublime_text", "Sublime Text", "com.sublimetext.4"),
    ("xed", "Xed", nil),
]

/// Look up display name + bundle ID for a process name. Returns nil when
/// the process name is not in the editor list.
public func editorInfo(processName name: String) -> (display: String, bundleID: String?)? {
    for (pn, dn, bid) in knownEditors {
        if name == pn || name.hasPrefix("\(pn) ") { return (dn, bid) }
    }
    return nil
}

/// Choose the user-visible "driver" of the trigger.
///   1. Claude Code (when a claude session was detected)
///   2. A known editor / IDE process in the chain (VS Code, vim, Emacs, …)
///   3. The first shell in the chain (zsh, bash, fish, …)
///   4. Fallback: the immediate parent process name
public func driverDescription(
    chain: [ProcessNode],
    claudeSession: String?
) -> DriverInfo {
    if claudeSession != nil {
        return DriverInfo(text: "Claude Code", kind: .claude, bundleID: nil)
    }
    let afterTrigger = chain.dropFirst()
    for node in afterTrigger {
        if let info = editorInfo(processName: node.name) {
            return DriverInfo(text: info.display, kind: .editor, bundleID: info.bundleID)
        }
    }
    if let shell = afterTrigger.first(where: { shellProcessNames.contains($0.name) }) {
        return DriverInfo(text: shell.name, kind: .shell, bundleID: nil)
    }
    if let parent = afterTrigger.first {
        return DriverInfo(text: parent.name, kind: .other, bundleID: nil)
    }
    return DriverInfo(text: chain.first?.name ?? "unknown", kind: .other, bundleID: nil)
}

/// Format a trigger argv array as a one-line command for display.
/// Strips path prefix on argv[0] so we show `op item list`, not
/// `/usr/local/bin/op item list`.
///
/// Special-cases SSH commit signing (`op-ssh-sign`, `ssh-keygen -Y sign -n git`):
/// the real argv is dominated by tempfile paths and unreadable in the overlay,
/// so we synthesize "signing a commit in <cwd>" instead.
public func operationDisplay(argv: [String], chain: [ProcessNode], cwd: String? = nil) -> String {
    if argv.isEmpty {
        // No argv available (1Password helper, or a sandbox restriction).
        // Fall back to the trigger process name with no args.
        return chain.first?.name ?? "(unknown command)"
    }
    let exe = (argv[0] as NSString).lastPathComponent
    if isGitCommitSigning(exe: exe, argv: argv) {
        if let cwd = cwd, !cwd.isEmpty {
            return "signing a commit in \(cwd)"
        }
        return "signing a commit"
    }
    var parts = argv
    parts[0] = exe
    return parts.joined(separator: " ")
}

/// Detect `op-ssh-sign` / `ssh-keygen` invoked specifically for git commit
/// signing (`-n git`). Returns false for plain `ssh-keygen` keygen/conversion
/// operations, which wouldn't be talking to the 1Password agent.
private func isGitCommitSigning(exe: String, argv: [String]) -> Bool {
    guard exe == "op-ssh-sign" || exe == "ssh-keygen" else { return false }
    var sawSign = false
    for a in argv.dropFirst() {
        if a == "sign" { sawSign = true }
        if a == "git" { return sawSign }  // `-n git` is the namespace flag value
    }
    return false
}

/// Parse `op` argv into a phrase like "read op://X/Y" or "use ‘op item get …’".
/// Returns nil when argv doesn't look like an op invocation.
public func describeOpInvocation(argv: [String]) -> String? {
    guard argv.count >= 2,
          (argv[0] as NSString).lastPathComponent == "op" else { return nil }

    // Skip leading flags to find the subcommand and its arguments.
    let rest = Array(argv.dropFirst()).drop(while: { $0.hasPrefix("-") })
    guard let sub = rest.first else { return nil }
    let subArgs = Array(rest.dropFirst()).filter { !$0.hasPrefix("-") }

    switch sub {
    case "read":
        if let uri = subArgs.first(where: { $0.hasPrefix("op://") }) {
            return "read \(uri)"
        }
        if let uri = subArgs.first {
            return "read \(uri)"
        }
        return "use ‘op read’"
    case "signin", "signout":
        return sub == "signin" ? "sign in to 1Password" : "sign out of 1Password"
    case "inject":
        return "inject secrets via ‘op inject’"
    case "run":
        return "run a command with ‘op run’"
    case "item", "vault", "document", "user", "group", "account", "ssh", "connect", "service-account", "events-api":
        if let action = subArgs.first {
            return "use ‘op \(sub) \(action)’"
        }
        return "use ‘op \(sub)’"
    default:
        return "run ‘op \(sub)’"
    }
}

/// Parse `git` argv to find the subcommand (e.g. "fetch", "push").
/// Skips `-C <path>`, `-c key=val`, and other global flags.
public func describeGitInvocation(argv: [String]) -> String? {
    guard !argv.isEmpty,
          (argv[0] as NSString).lastPathComponent == "git" else { return nil }

    var i = 1
    while i < argv.count {
        let a = argv[i]
        if a == "-C" || a == "-c" || a == "--git-dir" || a == "--work-tree" || a == "--namespace" {
            i += 2  // flag with value
            continue
        }
        if a.hasPrefix("-") {
            i += 1
            continue
        }
        return a
    }
    return nil
}

/// Git subcommands that may need network access — and therefore may trigger
/// an SSH key approval via 1Password's SSH agent.  Anything outside this set
/// is local-only and should be filtered out as a trigger candidate (so e.g.
/// a `git show` running in another tab never appears as a 1P dialog cause).
private let networkGitSubcommands: Set<String> = [
    "fetch", "pull", "push", "clone", "ls-remote", "archive",
    "remote", "submodule", "send-pack", "receive-pack", "upload-pack",
    "fetch-pack",
]

/// True iff the given git argv is for a subcommand that may need network /
/// SSH access. Unknown / local subcommands return false.
public func isRemoteGitSubcommand(argv: [String]) -> Bool {
    guard let sub = describeGitInvocation(argv: argv) else { return false }
    return networkGitSubcommands.contains(sub)
}

// MARK: - Actor / context labels
//
// Kind classification and the verb-phrase rendering used to live here; both
// are now produced by `RequestRuleEngine` from a user-editable rule list
// (see `RequestRule.swift`). Everything below is contextual labelling that
// runs whether the matched rule replaces the actor or not.

private let shellNames: Set<String> = ["bash", "zsh", "fish", "sh", "tcsh", "ksh", "dash"]

private func describeActor(
    chain: [ProcessNode],
    tabTitle: String?,
    claudeSession: String?,
    terminalBundleID: String?
) -> String {
    let isCmux = isCmuxBundleID(terminalBundleID)
    let workspaceName: String? = (isCmux && tabTitle != nil && !looksGeneric(tabTitle: tabTitle!)) ? tabTitle : nil

    if claudeSession != nil {
        if let workspace = workspaceName {
            return "Claude Code in cmux workspace ‘\(workspace)’"
        }
        if let term = humanTerminalName(bundleID: terminalBundleID),
           !isCmux,
           let title = tabTitle,
           !looksGeneric(tabTitle: title) {
            return "Claude Code in \(term) tab ‘\(title)’"
        }
        return "Claude Code session ‘\(claudeSession!)’"
    }

    if let workspace = workspaceName {
        return "cmux workspace ‘\(workspace)’"
    }
    if let title = tabTitle, !looksGeneric(tabTitle: title) {
        if let term = humanTerminalName(bundleID: terminalBundleID), !isCmux {
            return "\(term) tab ‘\(title)’"
        }
        return "Terminal tab ‘\(title)’"
    }
    if let shell = chain.first(where: { shellNames.contains($0.name) }) {
        return "Your \(shell.name) shell"
    }
    if let term = humanTerminalName(bundleID: terminalBundleID) {
        return "Your \(term) session"
    }
    if let pid = chain.first?.pid {
        return "Process \(pid)"
    }
    return "An unknown process"
}

/// Filter out tab titles that are just default shell prompts and add no clarity.
/// (e.g. "bash", "zsh", "user@host", "user@host: /Users/x".)
///
/// Also filters cmux's `Item-N` AX-window-title placeholder. cmux exposes a
/// window like "Item-0" to NSAccessibility while the actual user-visible
/// workspace name lives in cmux's own scripting interface (queried via
/// `CmuxHelper.surfaceInfo`). When that surface lookup misses we end up
/// here with `tabTitle == "Item-0"` — which rendered as
/// `'cmux workspace 'Item-0'` in the overlay until this filter caught it.
private func looksGeneric(tabTitle: String) -> Bool {
    let trimmed = tabTitle.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return true }
    if shellNames.contains(trimmed) { return true }
    if trimmed.contains("@") && trimmed.range(of: " ") == nil { return true }
    if trimmed.contains("@") && trimmed.contains(": ") { return true }
    if isItemPlaceholder(trimmed) { return true }
    return false
}

/// True for cmux's `Item-<digits>` placeholder titles. Matches `Item-0`,
/// `Item-42`, etc. Anything else falls through.
private func isItemPlaceholder(_ s: String) -> Bool {
    guard s.hasPrefix("Item-") else { return false }
    let suffix = s.dropFirst("Item-".count)
    return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
}

