import Foundation

/// Inputs the rule engine evaluates against. Built from the same fields the
/// overlay already extracts; nothing new is computed here.
public struct MatchContext {
    public let chain: [ProcessNode]
    public let triggerArgv: [String]
    /// `bestCWD` of the chain, already tidied. nil/"" when unavailable.
    public let cwd: String?
    /// The trigger process's own CWD, untidied. Used for prefix matching
    /// against locations like `~/.claude/plugins/`.
    public let triggerCwd: String?
    public let claudeSession: String?
    public let pluginUpdate: ClaudePluginUpdate?
    public let terminalBundleID: String?

    public init(
        chain: [ProcessNode],
        triggerArgv: [String],
        cwd: String?,
        triggerCwd: String?,
        claudeSession: String?,
        pluginUpdate: ClaudePluginUpdate?,
        terminalBundleID: String?
    ) {
        self.chain = chain
        self.triggerArgv = triggerArgv
        self.cwd = cwd
        self.triggerCwd = triggerCwd
        self.claudeSession = claudeSession
        self.pluginUpdate = pluginUpdate
        self.terminalBundleID = terminalBundleID
    }

    /// The canonical trigger process name, as reported by kinfo_proc.
    /// (argv[0] may be a path; this is the short name the engine matches on.)
    public var triggerName: String { chain.first?.name ?? "" }

    /// True iff the trigger binary's signing cert matches a publisher
    /// in `OpWhoConfig.trustedTeamIDs`. ProcessTree only computes this
    /// for `op` today; other processes always read false.
    public var binaryVerified: Bool { chain.first?.isVerifiedOnePasswordCLI ?? false }
}

/// Identifies which `MatchContext` field a `RegexCapture` runs against.
public enum RegexCaptureSource: String, Codable, Equatable, CaseIterable {
    /// `ctx.pluginUpdate?.remoteURL`.
    case pluginRemote
    /// `ctx.cwd`.
    case cwd
    /// `ctx.triggerCwd`.
    case triggerCwd
    /// `ctx.triggerArgv` joined with a single space.
    case argvJoined
}

/// Runs `pattern` (NSRegularExpression syntax) against one
/// `MatchContext`-derived string. Acts as both an additional matcher
/// predicate (rule only matches if the regex matches) and the source of
/// `$N` capture groups in the template.
public struct RegexCapture: Codable, Equatable {
    public var source: RegexCaptureSource
    public var pattern: String

    public init(source: RegexCaptureSource, pattern: String) {
        self.source = source
        self.pattern = pattern
    }

    /// Resolve the source string from `ctx`. Returns nil/"" when the
    /// chosen field is missing — the matcher treats that as no-match.
    public func sourceValue(in ctx: MatchContext) -> String? {
        switch source {
        case .pluginRemote: return ctx.pluginUpdate?.remoteURL
        case .cwd: return ctx.cwd
        case .triggerCwd: return ctx.triggerCwd
        case .argvJoined:
            return ctx.triggerArgv.isEmpty ? nil : ctx.triggerArgv.joined(separator: " ")
        }
    }

    /// First-match capture groups. Index 0 is the whole match; 1…n are
    /// the parenthesised groups. Empty array on no source / no match /
    /// invalid pattern.
    public func captures(in ctx: MatchContext) -> [String] {
        guard let src = sourceValue(in: ctx), !src.isEmpty,
              let re = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(src.startIndex..., in: src)
        guard let m = re.firstMatch(in: src, range: range) else { return [] }
        var out: [String] = []
        out.reserveCapacity(m.numberOfRanges)
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: src) {
                out.append(String(src[r]))
            } else {
                out.append("")
            }
        }
        return out
    }
}

/// All-of (AND) predicate over a MatchContext. Each field is optional;
/// nil means "don't constrain". An empty RequestMatcher matches everything.
public struct RequestMatcher: Codable, Equatable {
    /// Trigger process name (chain[0].name). Any-of.
    public var processName: [String]?
    /// First non-flag argv token after argv[0]. Any-of. Skips `-C value`,
    /// `-c key=val`, `--git-dir=…`, `--work-tree`, `--namespace`, and
    /// any single-token `-x` / `--key=value`.
    public var subcommand: [String]?
    /// Every token must appear somewhere in argv (after stripping path
    /// from argv[0]).
    public var argvContainsAll: [String]?
    /// Trigger process's own CWD must start with this prefix. `~` is
    /// expanded to $HOME.
    public var triggerCwdPrefix: String?
    /// The trigger binary's signing cert must (true) or must-not (false)
    /// match a publisher in `OpWhoConfig.trustedTeamIDs`. Today the
    /// signature is only computed for `op`; rules constraining this on
    /// any other process will simply never match.
    public var binaryVerified: Bool?
    /// Plugin-update info must be present (true) or absent (false).
    public var requiresPluginUpdate: Bool?
    /// Optional regex predicate. When set, the chosen source field must
    /// exist, be non-empty, and match `pattern`. Capture groups are
    /// available in the template as `$0` (full match), `$1`, `$2`, …
    public var regex: RegexCapture?

    public init(
        processName: [String]? = nil,
        subcommand: [String]? = nil,
        argvContainsAll: [String]? = nil,
        triggerCwdPrefix: String? = nil,
        binaryVerified: Bool? = nil,
        requiresPluginUpdate: Bool? = nil,
        regex: RegexCapture? = nil
    ) {
        self.processName = processName
        self.subcommand = subcommand
        self.argvContainsAll = argvContainsAll
        self.triggerCwdPrefix = triggerCwdPrefix
        self.binaryVerified = binaryVerified
        self.requiresPluginUpdate = requiresPluginUpdate
        self.regex = regex
    }

    /// JSON keys. `binaryVerified` is persisted as `opVerified` for
    /// backward compatibility with rules.json files written before the
    /// concept was generalized.
    enum CodingKeys: String, CodingKey {
        case processName, subcommand, argvContainsAll, triggerCwdPrefix
        case binaryVerified = "opVerified"
        case requiresPluginUpdate
        case regex
    }

    public func matches(_ ctx: MatchContext) -> Bool {
        if let names = processName, !names.contains(ctx.triggerName) {
            return false
        }
        if let subs = subcommand {
            guard let s = parseSubcommand(argv: ctx.triggerArgv), subs.contains(s) else {
                return false
            }
        }
        if let needles = argvContainsAll {
            for token in needles {
                if !ctx.triggerArgv.contains(token) { return false }
            }
        }
        if let prefix = triggerCwdPrefix {
            let expanded = expandTilde(prefix)
            guard let cwd = ctx.triggerCwd, cwd.hasPrefix(expanded) else {
                return false
            }
        }
        if let want = binaryVerified, ctx.binaryVerified != want {
            return false
        }
        if let want = requiresPluginUpdate {
            let have = (ctx.pluginUpdate != nil)
            if want != have { return false }
        }
        if let r = regex {
            if r.captures(in: ctx).isEmpty { return false }
        }
        return true
    }

    /// Capture groups bound by the matcher's regex, or `[]` when no
    /// regex is configured. Index 0 is the full match; 1…n are the
    /// parenthesised groups. Exposed so the engine can pass them to the
    /// template renderer without re-running the regex.
    public func captures(in ctx: MatchContext) -> [String] {
        regex?.captures(in: ctx) ?? []
    }

    /// Single-line summary for the config UI table.
    public var displaySummary: String {
        var parts: [String] = []
        if let names = processName, !names.isEmpty {
            parts.append(names.joined(separator: "|"))
        }
        if let subs = subcommand, !subs.isEmpty {
            parts.append("sub=" + subs.joined(separator: "|"))
        }
        if let argv = argvContainsAll, !argv.isEmpty {
            parts.append("argv⊇{" + argv.joined(separator: ",") + "}")
        }
        if let p = triggerCwdPrefix, !p.isEmpty {
            parts.append("cwd^=" + p)
        }
        if let v = binaryVerified { parts.append(v ? "verified" : "unverified") }
        if requiresPluginUpdate == true { parts.append("plugin-update") }
        if requiresPluginUpdate == false { parts.append("no-plugin-update") }
        if let r = regex { parts.append("re[\(r.source.rawValue)]=\(r.pattern)") }
        return parts.isEmpty ? "(any)" : parts.joined(separator: " · ")
    }
}

/// One ordered rule in the matcher list: predicate + the description shown
/// in the overlay when it wins.
public struct RequestRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var matcher: RequestMatcher
    /// Template with `{process}`, `{subcommand}`, `{argv}`, `{cwd}`,
    /// `{op_uri}`, `{plugin_remote}`, `{repo}`, `{source}`, `{marketplace}`,
    /// `{argv[N]}` named placeholders and `$0`/`$1`/… regex capture
    /// placeholders. A rule that references a placeholder which resolves
    /// to empty does NOT match — the engine falls through to the next rule.
    public var template: String
    /// When true, `template` is the full title (actor prefix is suppressed).
    public var replacesActor: Bool
    public var kind: RequestKind
    public var isWarning: Bool
    /// Stable, release-spanning identifier for rules shipped in
    /// `RequestRule.builtIns`. Nil for user-authored rules. Used by the
    /// store to track which built-ins the user has disabled and by
    /// `RequestRule.builtIn(id:)` to look one up. Must never change
    /// across releases once shipped — renaming a builtIn means picking
    /// a new ID counts as removing the old one for users who disabled it.
    public var builtInID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        matcher: RequestMatcher,
        template: String,
        replacesActor: Bool = false,
        kind: RequestKind,
        isWarning: Bool = false,
        builtInID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.matcher = matcher
        self.template = template
        self.replacesActor = replacesActor
        self.kind = kind
        self.isWarning = isWarning
        self.builtInID = builtInID
    }
}

/// Result of running the rule engine over a context.
public struct MatchResult: Equatable {
    public let rule: RequestRule
    public let rendered: String
}

public enum RequestRuleEngine {
    /// First-match-wins. A rule whose template references a placeholder
    /// that resolves to empty is treated as a non-match so the engine
    /// falls through to the next rule.
    public static func evaluate(rules: [RequestRule], context: MatchContext) -> MatchResult? {
        for rule in rules {
            guard rule.matcher.matches(context) else { continue }
            let captures = rule.matcher.captures(in: context)
            guard let rendered = renderTemplate(rule.template, context: context, captures: captures) else {
                continue
            }
            return MatchResult(rule: rule, rendered: rendered)
        }
        return nil
    }
}

/// Render `template` against `context`. Returns nil when the template
/// references a placeholder that resolves to an empty string — the engine
/// uses that signal to fall through to the next rule.
///
/// Two placeholder syntaxes are supported:
///   - `{name}` — named context fields (`{process}`, `{cwd}`, …)
///   - `$N` — capture group `N` from the matcher's regex (0 = whole
///     match). `$$` renders a literal `$`. `$` followed by a non-digit,
///     non-`$` character is treated as a literal `$`.
public func renderTemplate(_ template: String, context: MatchContext, captures: [String] = []) -> String? {
    var out = ""
    var i = template.startIndex
    while i < template.endIndex {
        let c = template[i]
        if c == "{" {
            guard let close = template[i...].firstIndex(of: "}") else {
                out.append(c)
                i = template.index(after: i)
                continue
            }
            let key = String(template[template.index(after: i)..<close])
            let value = resolvePlaceholder(key, context: context)
            if value.isEmpty { return nil }
            out.append(value)
            i = template.index(after: close)
        } else if c == "$" {
            let next = template.index(after: i)
            if next < template.endIndex, template[next] == "$" {
                out.append("$")
                i = template.index(after: next)
                continue
            }
            var j = next
            while j < template.endIndex, template[j].isASCII, template[j].isNumber {
                j = template.index(after: j)
            }
            if j == next {
                out.append(c)
                i = next
                continue
            }
            guard let n = Int(template[next..<j]),
                  n >= 0, n < captures.count else {
                return nil
            }
            let value = captures[n]
            if value.isEmpty { return nil }
            out.append(value)
            i = j
        } else {
            out.append(c)
            i = template.index(after: i)
        }
    }
    return out
}

private func resolvePlaceholder(_ key: String, context: MatchContext) -> String {
    switch key {
    case "process":
        // The fallback rule's template references {process}; without a known
        // trigger we still want it to render (with a "?" placeholder) so the
        // rule never fails purely because chain[] was empty.
        let name = context.triggerName
        return name.isEmpty ? "?" : name
    case "subcommand":
        return parseSubcommand(argv: context.triggerArgv) ?? ""
    case "argv":
        guard !context.triggerArgv.isEmpty else { return "" }
        return operationDisplay(argv: context.triggerArgv, chain: context.chain, cwd: context.cwd)
    case "cwd":
        guard let c = context.cwd, !c.isEmpty, c != "/" else { return "" }
        return c
    case "op_uri":
        return context.triggerArgv.first(where: { $0.hasPrefix("op://") }) ?? ""
    case "op_phrase":
        // Preserves the original `describeOpInvocation` phrasing — useful
        // for the "unverified op" rule which wraps the parsed phrase in
        // parens. Returns "" when argv is too short to parse, which
        // (intentionally) causes the rule to fall through.
        return describeOpInvocation(argv: context.triggerArgv) ?? ""
    case "plugin_remote":
        return context.pluginUpdate?.remoteURL ?? ""
    case "repo":
        return context.pluginUpdate?.repo ?? ""
    case "source":
        return context.pluginUpdate?.sourceType ?? ""
    case "marketplace":
        return context.pluginUpdate?.marketplaceName ?? ""
    default:
        if key.hasPrefix("argv[") && key.hasSuffix("]") {
            let inside = key.dropFirst("argv[".count).dropLast()
            if let idx = Int(inside), idx >= 0, idx < context.triggerArgv.count {
                return context.triggerArgv[idx]
            }
            return ""
        }
        return ""
    }
}

/// Parse the first non-flag argv token after argv[0]. Skips:
///   - `-C value`, `-c value`, `--git-dir value`, `--work-tree value`,
///     `--namespace value` (two-token flag forms)
///   - any other token starting with `-` (including `--key=value`)
/// Returns nil when argv is empty or no non-flag token remains.
public func parseSubcommand(argv: [String]) -> String? {
    guard !argv.isEmpty else { return nil }
    let pairFlags: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"]
    var i = 1
    while i < argv.count {
        let a = argv[i]
        if pairFlags.contains(a) {
            i += 2
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

private func expandTilde(_ path: String) -> String {
    if path == "~" {
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if path.hasPrefix("~/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst(1)
    }
    return path
}

// MARK: - Built-in ruleset

extension RequestRule {
    /// Rules shipped with the binary. The store merges these (filtered
    /// by `disabledBuiltInIDs`) after any user-authored rules.
    ///
    /// `static let` (not `var`) so the per-process UUIDs are assigned
    /// once per program run — keeps rule identity stable for the ring
    /// buffer's `matchedRuleID` links within a session. Across releases,
    /// `builtInID` (the stable string slug) is what survives.
    ///
    /// **Stability contract**: once shipped, a built-in's `builtInID` is
    /// frozen. Renaming or rewording a rule keeps the same ID so users
    /// who disabled it keep it disabled across upgrades. Retiring a rule
    /// means removing the entry; its ID then dangles harmlessly in
    /// users' `disabledBuiltInIDs` sets.
    public static let builtIns: [RequestRule] = [
            // 1a. Claude plugin housekeeping — structured display when
            // we can resolve the marketplace via known_marketplaces.json
            // ({repo} and {source} both empty → rule falls through).
            RequestRule(
                name: "Claude plugin update (known marketplace)",
                matcher: RequestMatcher(
                    processName: ["git"],
                    requiresPluginUpdate: true
                ),
                template: "Claude plugin update check for {repo} ({source})",
                replacesActor: true,
                kind: .ssh,
                builtInID: "plugin-update-known-marketplace"
            ),
            // 1b. Claude plugin housekeeping — fallback when the
            // marketplace lookup missed (file absent, entry not yet
            // written, or non-marketplace plugin repo). Shows the raw
            // remote URL.
            RequestRule(
                name: "Claude plugin update",
                matcher: RequestMatcher(
                    processName: ["git"],
                    requiresPluginUpdate: true
                ),
                template: "Claude plugin update check from {plugin_remote}",
                replacesActor: true,
                kind: .ssh,
                builtInID: "plugin-update-fallback"
            ),
            // 2a. Commit signing with a known cwd.
            RequestRule(
                name: "Commit signing (with cwd)",
                matcher: RequestMatcher(
                    processName: ["op-ssh-sign", "ssh-keygen"],
                    argvContainsAll: ["sign", "git"]
                ),
                template: "is signing a commit in {cwd}",
                kind: .ssh,
                builtInID: "commit-signing-with-cwd"
            ),
            // 2b. Commit signing fallback (no cwd).
            RequestRule(
                name: "Commit signing",
                matcher: RequestMatcher(
                    processName: ["op-ssh-sign", "ssh-keygen"],
                    argvContainsAll: ["sign", "git"]
                ),
                template: "is signing a commit",
                kind: .ssh,
                builtInID: "commit-signing"
            ),
            // 3. Other SSH signing (key conversion, fingerprinting via 1Password agent).
            RequestRule(
                name: "Other SSH signing",
                matcher: RequestMatcher(processName: ["op-ssh-sign", "ssh-keygen"]),
                template: "is signing with an SSH key",
                kind: .ssh,
                builtInID: "other-ssh-signing"
            ),
            // 4. Git network subcommand.
            RequestRule(
                name: "Git network operation",
                matcher: RequestMatcher(
                    processName: ["git"],
                    subcommand: [
                        "fetch", "pull", "push", "clone", "ls-remote", "archive",
                        "remote", "submodule", "send-pack", "receive-pack",
                        "upload-pack", "fetch-pack",
                    ]
                ),
                template: "needs an SSH key for ‘git {subcommand}’",
                kind: .ssh,
                builtInID: "git-network"
            ),
            // 5. Git fallback (no recognized subcommand — preserves legacy test).
            RequestRule(
                name: "Git fallback",
                matcher: RequestMatcher(processName: ["git"]),
                template: "needs an SSH key (via ‘git’)",
                kind: .ssh,
                builtInID: "git-fallback"
            ),
            // 6. Plain ssh — no "via" qualifier per existing UX.
            RequestRule(
                name: "ssh",
                matcher: RequestMatcher(processName: ["ssh"]),
                template: "needs an SSH key",
                kind: .ssh,
                builtInID: "ssh"
            ),
            // 7. scp / sftp / rsync — qualified with the tool name.
            RequestRule(
                name: "scp / sftp / rsync",
                matcher: RequestMatcher(processName: ["scp", "sftp", "rsync"]),
                template: "needs an SSH key (via ‘{process}’)",
                kind: .ssh,
                builtInID: "scp-sftp-rsync"
            ),
            // 8a. Unverified op CLI with a parseable op invocation. Uses the
            // {op_phrase} placeholder so the parens read identically to the
            // pre-engine output ("(read op://X/Y)") rather than including
            // the binary name twice.
            RequestRule(
                name: "Unverified op (with phrase)",
                matcher: RequestMatcher(processName: ["op"], binaryVerified: false),
                template: "is running an unverified ‘op’ binary ({op_phrase})",
                kind: .unverifiedOp,
                isWarning: true,
                builtInID: "unverified-op-with-phrase"
            ),
            // 8b. Unverified op fallback.
            RequestRule(
                name: "Unverified op",
                matcher: RequestMatcher(processName: ["op"], binaryVerified: false),
                template: "is running an unverified ‘op’ binary",
                kind: .unverifiedOp,
                isWarning: true,
                builtInID: "unverified-op"
            ),
            // 9a. op read with explicit URI.
            RequestRule(
                name: "op read (URI)",
                matcher: RequestMatcher(
                    processName: ["op"], subcommand: ["read"], binaryVerified: true
                ),
                template: "wants to read {op_uri}",
                kind: .onePasswordCLI,
                builtInID: "op-read-uri"
            ),
            // 9b. op read fallback (no URI parsed).
            RequestRule(
                name: "op read",
                matcher: RequestMatcher(
                    processName: ["op"], subcommand: ["read"], binaryVerified: true
                ),
                template: "wants to use ‘op read’",
                kind: .onePasswordCLI,
                builtInID: "op-read"
            ),
            // 10. op signin.
            RequestRule(
                name: "op signin",
                matcher: RequestMatcher(
                    processName: ["op"], subcommand: ["signin"], binaryVerified: true
                ),
                template: "wants to sign in to 1Password",
                kind: .onePasswordCLI,
                builtInID: "op-signin"
            ),
            // 11. op signout.
            RequestRule(
                name: "op signout",
                matcher: RequestMatcher(
                    processName: ["op"], subcommand: ["signout"], binaryVerified: true
                ),
                template: "wants to sign out of 1Password",
                kind: .onePasswordCLI,
                builtInID: "op-signout"
            ),
            // 12. op inject.
            RequestRule(
                name: "op inject",
                matcher: RequestMatcher(
                    processName: ["op"], subcommand: ["inject"], binaryVerified: true
                ),
                template: "wants to inject secrets via ‘op inject’",
                kind: .onePasswordCLI,
                builtInID: "op-inject"
            ),
            // 13. op run.
            RequestRule(
                name: "op run",
                matcher: RequestMatcher(
                    processName: ["op"], subcommand: ["run"], binaryVerified: true
                ),
                template: "wants to run a command with ‘op run’",
                kind: .onePasswordCLI,
                builtInID: "op-run"
            ),
            // 14a. Known resource group with action — "op vault list".
            RequestRule(
                name: "op resource action",
                matcher: RequestMatcher(
                    processName: ["op"],
                    subcommand: [
                        "item", "vault", "document", "user", "group", "account",
                        "ssh", "connect", "service-account", "events-api",
                    ],
                    binaryVerified: true
                ),
                template: "wants to use ‘op {subcommand} {argv[2]}’",
                kind: .onePasswordCLI,
                builtInID: "op-resource-with-action"
            ),
            // 14b. Same resource group without action — "op vault".
            RequestRule(
                name: "op resource",
                matcher: RequestMatcher(
                    processName: ["op"],
                    subcommand: [
                        "item", "vault", "document", "user", "group", "account",
                        "ssh", "connect", "service-account", "events-api",
                    ],
                    binaryVerified: true
                ),
                template: "wants to use ‘op {subcommand}’",
                kind: .onePasswordCLI,
                builtInID: "op-resource"
            ),
            // 15. Any other op subcommand — "wants to run 'op something'".
            RequestRule(
                name: "op other subcommand",
                matcher: RequestMatcher(processName: ["op"], binaryVerified: true),
                template: "wants to run ‘op {subcommand}’",
                kind: .onePasswordCLI,
                builtInID: "op-other-subcommand"
            ),
            // 16. op with no parseable subcommand.
            RequestRule(
                name: "op (no subcommand)",
                matcher: RequestMatcher(processName: ["op"], binaryVerified: true),
                template: "is using the 1Password CLI",
                kind: .onePasswordCLI,
                builtInID: "op-no-subcommand"
            ),
            // 17. Fallback: anything unrecognized.
            RequestRule(
                name: "Unknown trigger",
                matcher: RequestMatcher(),
                template: "triggered 1Password (via ‘{process}’)",
                kind: .unknown,
                isWarning: true,
                builtInID: "unknown-trigger"
            ),
    ]

    /// Look up a built-in by its stable ID. Returns nil for unknown IDs
    /// (e.g. an ID from a retired built-in that's still in a user's
    /// `disabledBuiltInIDs` set).
    public static func builtIn(id: String) -> RequestRule? {
        builtIns.first { $0.builtInID == id }
    }
}

/// Globals consulted by the engine and the signing checks. The app sets
/// these once at startup from the user's stored configuration; tests get
/// the built-in defaults.
public enum OpWhoConfig {
    /// Ordered rule list evaluated by `makeRequestSummary`. Composed by
    /// the store as `userRules + (builtIns − disabledBuiltInIDs)`.
    public static var rules: [RequestRule] = RequestRule.builtIns
    /// Apple Team IDs (subject.OU) that ProcessTree's signing-cert checks
    /// treat as trusted — used both to mark trigger binaries verified
    /// (for the matcher's `binaryVerified` predicate) and to gate the
    /// AX-observer attach to the 1Password app.
    public static var trustedTeamIDs: [String] = TrustedPublisher.defaults.map { $0.teamID }
}
