import Testing
import Foundation
import Darwin
@testable import OpWhoLib

private func node(_ name: String, pid: pid_t = 100, verified: Bool = false) -> ProcessNode {
    ProcessNode(
        pid: pid, ppid: 1, name: name, tty: nil,
        executablePath: nil, isVerifiedOnePasswordCLI: verified
    )
}

private func ctx(
    chain: [ProcessNode],
    argv: [String] = [],
    cwd: String? = nil,
    triggerCwd: String? = nil,
    claudeSession: String? = nil,
    pluginUpdate: ClaudePluginUpdate? = nil,
    terminalBundleID: String? = nil
) -> MatchContext {
    MatchContext(
        chain: chain, triggerArgv: argv, cwd: cwd, triggerCwd: triggerCwd,
        claudeSession: claudeSession, pluginUpdate: pluginUpdate,
        terminalBundleID: terminalBundleID
    )
}

@Suite("RequestMatcher")
struct RequestMatcherTests {

    @Test func emptyMatcherMatchesEverything() {
        let m = RequestMatcher()
        #expect(m.matches(ctx(chain: [node("op", verified: true)])))
        #expect(m.matches(ctx(chain: [])))
        #expect(m.matches(ctx(chain: [node("anything")], argv: ["x", "y"])))
    }

    @Test func processNameAndOpVerifiedAreANDed() {
        let m = RequestMatcher(processName: ["op"], binaryVerified: true)
        #expect(m.matches(ctx(chain: [node("op", verified: true)])))
        #expect(!m.matches(ctx(chain: [node("op", verified: false)])))
        #expect(!m.matches(ctx(chain: [node("ssh", verified: true)])))
    }

    @Test func subcommandSkipsLeadingFlags() {
        let m = RequestMatcher(processName: ["git"], subcommand: ["push"])
        #expect(m.matches(ctx(
            chain: [node("git")],
            argv: ["git", "-C", "/tmp", "-c", "color.ui=false", "push", "origin"]
        )))
        #expect(!m.matches(ctx(
            chain: [node("git")],
            argv: ["git", "-C", "/tmp", "fetch"]
        )))
    }

    @Test func argvContainsAllNeedsEveryToken() {
        let m = RequestMatcher(argvContainsAll: ["sign", "git"])
        #expect(m.matches(ctx(chain: [node("op-ssh-sign")], argv: ["op-ssh-sign", "-Y", "sign", "-n", "git"])))
        #expect(!m.matches(ctx(chain: [node("op-ssh-sign")], argv: ["op-ssh-sign", "-Y", "sign", "-n", "ssh"])))
    }

    @Test func triggerCwdPrefixExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let m = RequestMatcher(triggerCwdPrefix: "~/.claude/plugins/")
        #expect(m.matches(ctx(chain: [node("git")], triggerCwd: home + "/.claude/plugins/foo")))
        #expect(!m.matches(ctx(chain: [node("git")], triggerCwd: home + "/git/x")))
    }

    @Test func pluginUpdatePresenceFiltersWork() {
        let yes = RequestMatcher(requiresPluginUpdate: true)
        let no = RequestMatcher(requiresPluginUpdate: false)
        let update = ClaudePluginUpdate(remoteURL: "git@github.com:foo/bar.git")
        #expect(yes.matches(ctx(chain: [node("git")], pluginUpdate: update)))
        #expect(!yes.matches(ctx(chain: [node("git")])))
        #expect(no.matches(ctx(chain: [node("git")])))
        #expect(!no.matches(ctx(chain: [node("git")], pluginUpdate: update)))
    }

    @Test func regexAgainstPluginRemoteIsPredicateAndCaptureSource() {
        let m = RequestMatcher(
            processName: ["git"],
            regex: RegexCapture(source: .pluginRemote,
                                pattern: #"github\.com[:/](.+?)(?:\.git)?$"#)
        )
        let match = ctx(
            chain: [node("git")],
            pluginUpdate: ClaudePluginUpdate(remoteURL: "git@github.com:foo/bar.git")
        )
        #expect(m.matches(match))
        #expect(m.captures(in: match) == ["github.com:foo/bar.git", "foo/bar"])

        // Same rule against a non-github remote — regex must not match,
        // so the matcher returns false (even though processName is fine).
        let miss = ctx(
            chain: [node("git")],
            pluginUpdate: ClaudePluginUpdate(remoteURL: "git@gitlab.com:foo/bar.git")
        )
        #expect(!m.matches(miss))
        #expect(m.captures(in: miss).isEmpty)
    }

    @Test func regexSourceWithMissingFieldIsNoMatch() {
        // .pluginRemote when no pluginUpdate is present → no source
        // value → no match (regression test: must not crash, must not
        // silently match against nil/empty).
        let m = RequestMatcher(
            regex: RegexCapture(source: .pluginRemote, pattern: ".*")
        )
        #expect(!m.matches(ctx(chain: [node("git")])))
    }

    @Test func regexAgainstArgvJoined() {
        let m = RequestMatcher(
            regex: RegexCapture(source: .argvJoined,
                                pattern: #"--remote=([^ ]+)"#)
        )
        let c = ctx(
            chain: [node("git")],
            argv: ["git", "push", "--remote=origin", "--tags"]
        )
        #expect(m.matches(c))
        #expect(m.captures(in: c)[1] == "origin")
    }

    @Test func invalidRegexPatternIsNoMatch() {
        // Malformed pattern → matcher must fail closed, never throw.
        let m = RequestMatcher(
            regex: RegexCapture(source: .argvJoined, pattern: "(unbalanced")
        )
        #expect(!m.matches(ctx(chain: [node("git")], argv: ["git", "x"])))
    }

    @Test func decodesLegacyOpVerifiedJsonKey() {
        // Pre-rename JSON used the key "opVerified". CodingKeys aliases it
        // to the renamed `binaryVerified` field so older rules.json files
        // keep working after upgrade.
        let json = #"""
        {"processName": ["op"], "opVerified": true}
        """#.data(using: .utf8)!
        let m = try! JSONDecoder().decode(RequestMatcher.self, from: json)
        #expect(m.binaryVerified == true)
        #expect(m.processName == ["op"])
    }

    @Test func displaySummaryIsReadable() {
        let m = RequestMatcher(
            processName: ["op"], subcommand: ["read"], binaryVerified: true
        )
        #expect(m.displaySummary.contains("op"))
        #expect(m.displaySummary.contains("read"))
        #expect(m.displaySummary.contains("verified"))
    }
}

@Suite("renderTemplate")
struct RenderTemplateTests {

    @Test func simplePlaceholders() {
        let c = ctx(chain: [node("git")], argv: ["git", "fetch", "origin"])
        #expect(renderTemplate("needs an SSH key for ‘git {subcommand}’", context: c) == "needs an SSH key for ‘git fetch’")
    }

    @Test func emptyPlaceholderCausesFallthrough() {
        // {op_uri} not present → render returns nil so the engine moves on.
        let c = ctx(chain: [node("op", verified: true)], argv: ["op", "read"])
        #expect(renderTemplate("wants to read {op_uri}", context: c) == nil)
    }

    @Test func unknownPlaceholderTreatedAsEmpty() {
        let c = ctx(chain: [node("op")])
        #expect(renderTemplate("hello {nope} world", context: c) == nil)
    }

    @Test func processPlaceholderFallsBackToQuestionMark() {
        // Fallback rule uses {process}; empty chain must still render so the
        // engine produces SOMETHING for unclassifiable triggers.
        let c = ctx(chain: [])
        #expect(renderTemplate("triggered 1Password (via ‘{process}’)", context: c) == "triggered 1Password (via ‘?’)")
    }

    @Test func argvIndexPlaceholder() {
        let c = ctx(chain: [node("op", verified: true)], argv: ["op", "item", "get", "GitHub"])
        #expect(renderTemplate("op {argv[1]} {argv[2]}", context: c) == "op item get")
        // Out-of-bounds index → empty → fallthrough.
        #expect(renderTemplate("op {argv[1]} {argv[9]}", context: c) == nil)
    }

    @Test func cwdSlashTreatedAsEmpty() {
        // "/" is not a useful cwd to surface; rules referencing {cwd} should
        // fall through when the chain only resolved to root.
        let c = ctx(chain: [node("op-ssh-sign")], argv: ["op-ssh-sign", "sign", "git"], cwd: "/")
        #expect(renderTemplate("is signing a commit in {cwd}", context: c) == nil)
        let c2 = ctx(chain: [node("op-ssh-sign")], argv: ["op-ssh-sign", "sign", "git"], cwd: "~/proj")
        #expect(renderTemplate("is signing a commit in {cwd}", context: c2) == "is signing a commit in ~/proj")
    }

    @Test func opPhrasePlaceholder() {
        let c = ctx(chain: [node("op", verified: false)], argv: ["op", "read", "op://X/Y"])
        #expect(renderTemplate("({op_phrase})", context: c) == "(read op://X/Y)")
    }

    @Test func dollarNResolvesCaptureGroups() {
        let c = ctx(chain: [node("git")])
        let caps = ["github.com:foo/bar.git", "foo/bar", "bar"]
        #expect(renderTemplate("from github.com/$1 (repo $2)", context: c, captures: caps)
                == "from github.com/foo/bar (repo bar)")
    }

    @Test func dollarZeroIsFullMatch() {
        let c = ctx(chain: [node("git")])
        let caps = ["whole match", "g1"]
        #expect(renderTemplate("matched [$0]", context: c, captures: caps) == "matched [whole match]")
    }

    @Test func dollarOutOfBoundsCausesFallthrough() {
        let c = ctx(chain: [node("git")])
        #expect(renderTemplate("x=$1", context: c, captures: []) == nil)
        #expect(renderTemplate("x=$3", context: c, captures: ["m", "a"]) == nil)
    }

    @Test func emptyCaptureCausesFallthrough() {
        // Optional group that didn't participate in the match resolves
        // to "" — same convention as empty {placeholder} → fall through.
        let c = ctx(chain: [node("git")])
        #expect(renderTemplate("x=$1", context: c, captures: ["m", ""]) == nil)
    }

    @Test func doubleDollarEscapes() {
        let c = ctx(chain: [node("git")])
        #expect(renderTemplate("cost $$5 (was $1)", context: c, captures: ["m", "3"])
                == "cost $5 (was 3)")
    }

    @Test func dollarFollowedByNonDigitIsLiteral() {
        // Lenient: a stray `$x` in a template stays as `$x` rather than
        // exploding. Users who want `$1` as literal text should use
        // `$$1`.
        let c = ctx(chain: [node("git")])
        #expect(renderTemplate("hello $world", context: c, captures: []) == "hello $world")
        #expect(renderTemplate("end with $", context: c, captures: []) == "end with $")
    }
}

@Suite("RequestRuleEngine")
struct RequestRuleEngineTests {

    @Test func defaultsMatchPluginUpdateFirst() {
        // Marketplace lookup populated repo + sourceType → 1a wins and
        // renders the structured form.
        let update = ClaudePluginUpdate(
            remoteURL: "git@github.com:cloudflare/skills.git",
            repo: "cloudflare/skills",
            sourceType: "github",
            marketplaceName: "cloudflare"
        )
        let c = ctx(
            chain: [node("git"), node("node"), node("claude")],
            argv: ["git", "pull", "origin", "HEAD"],
            cwd: "~/.claude/plugins/marketplaces/cloudflare",
            triggerCwd: "/Users/x/.claude/plugins/marketplaces/cloudflare",
            claudeSession: "op-who",
            pluginUpdate: update,
            terminalBundleID: "com.googlecode.iterm2"
        )
        let result = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(result?.rendered == "Claude plugin update check for cloudflare/skills (github)")
        #expect(result?.rule.replacesActor == true)
        #expect(result?.rule.name == "Claude plugin update (known marketplace)")
    }

    @Test func defaultsPluginUpdateFallsBackWhenMarketplaceLookupMisses() {
        // Only remoteURL filled (e.g. known_marketplaces.json missing
        // or entry not present) → 1a's {repo}/{source} resolve empty →
        // engine falls through to 1b which echoes the raw URL.
        let update = ClaudePluginUpdate(remoteURL: "git@gitlab.com:acme/widgets.git")
        let c = ctx(
            chain: [node("git")],
            argv: ["git", "pull", "origin", "HEAD"],
            pluginUpdate: update
        )
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "Claude plugin update check from git@gitlab.com:acme/widgets.git")
        #expect(r?.rule.name == "Claude plugin update")
    }

    @Test func repoAndSourcePlaceholdersResolveFromMarketplace() {
        let update = ClaudePluginUpdate(
            remoteURL: "git@github.com:sunstoneinstitute/claude-plugins.git",
            repo: "sunstoneinstitute/claude-plugins",
            sourceType: "github",
            marketplaceName: "sunstone-plugins"
        )
        let c = ctx(chain: [node("git")], pluginUpdate: update)
        #expect(renderTemplate("{repo} via {source} ({marketplace})", context: c)
                == "sunstoneinstitute/claude-plugins via github (sunstone-plugins)")
    }

    @Test func repoPlaceholderFallsThroughWhenAbsent() {
        // No pluginUpdate at all → {repo} resolves to "" → render fails.
        let c = ctx(chain: [node("git")])
        #expect(renderTemplate("for {repo}", context: c) == nil)
    }

    @Test func defaultsHandleGitNetworkSubcommand() {
        let c = ctx(chain: [node("git")], argv: ["git", "fetch", "origin"])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "needs an SSH key for ‘git fetch’")
        #expect(r?.rule.kind == .ssh)
    }

    @Test func defaultsHandleGitFallback() {
        let c = ctx(chain: [node("git")], argv: [])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "needs an SSH key (via ‘git’)")
    }

    @Test func defaultsHandleOpReadWithUri() {
        let c = ctx(
            chain: [node("op", verified: true)],
            argv: ["op", "read", "op://Dev/Secret/cred"]
        )
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "wants to read op://Dev/Secret/cred")
    }

    @Test func defaultsHandleOpReadWithoutUri() {
        // {op_uri} empty → falls through to "op read" fallback rule.
        let c = ctx(chain: [node("op", verified: true)], argv: ["op", "read"])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "wants to use ‘op read’")
    }

    @Test func defaultsHandleUnverifiedOp() {
        let c = ctx(chain: [node("op", verified: false)], argv: [])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rule.kind == .unverifiedOp)
        #expect(r?.rule.isWarning == true)
    }

    @Test func defaultsHandleResourceWithAction() {
        let c = ctx(
            chain: [node("op", verified: true)],
            argv: ["op", "item", "get", "GitHub"]
        )
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "wants to use ‘op item get’")
    }

    @Test func defaultsHandleResourceWithoutAction() {
        // argv[2] missing → 14a falls through to 14b.
        let c = ctx(
            chain: [node("op", verified: true)],
            argv: ["op", "vault"]
        )
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "wants to use ‘op vault’")
    }

    @Test func defaultsFallbackForUnknownTrigger() {
        let c = ctx(chain: [node("weird-thing")])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rule.kind == .unknown)
        #expect(r?.rule.isWarning == true)
        #expect(r?.rendered.contains("weird-thing") == true)
    }

    @Test func defaultsFallbackForEmptyChain() {
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: ctx(chain: []))
        #expect(r?.rule.kind == .unknown)
        #expect(r?.rendered.contains("?") == true)
    }

    @Test func firstMatchWinsOverridesDefaults() {
        // A user-added override rule placed first should win even though a
        // built-in default would also match.
        let custom = RequestRule(
            name: "Custom op read",
            matcher: RequestMatcher(
                processName: ["op"], subcommand: ["read"], binaryVerified: true
            ),
            template: "is pulling ‘{op_uri}’ from 1Password",
            kind: .onePasswordCLI
        )
        let rules = [custom] + RequestRule.builtIns
        let c = ctx(
            chain: [node("op", verified: true)],
            argv: ["op", "read", "op://X/Y"]
        )
        let r = RequestRuleEngine.evaluate(rules: rules, context: c)
        #expect(r?.rule.id == custom.id)
        #expect(r?.rendered == "is pulling ‘op://X/Y’ from 1Password")
    }
}

@Suite("Stores")
struct StoresTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("op-who-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func ruleStoreFreshInstallShowsAllBuiltIns() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        #expect(store.userRules.isEmpty)
        #expect(store.disabledBuiltInIDs.isEmpty)
        #expect(store.allRules == RequestRule.builtIns)
    }

    @Test func ruleStoreRoundTripsUserRulesAndDisabledBuiltIns() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        let custom = RequestRule(
            name: "Custom",
            matcher: RequestMatcher(processName: ["ssh"]),
            template: "hi",
            kind: .ssh
        )
        store.setUserRules([custom])
        store.setBuiltInDisabled(id: "git-fallback", disabled: true)
        store.setBuiltInDisabled(id: "ssh", disabled: true)

        let reloaded = RequestRuleStore(fileURL: url)
        #expect(reloaded.userRules.count == 1)
        #expect(reloaded.userRules.first?.name == "Custom")
        #expect(reloaded.disabledBuiltInIDs == ["git-fallback", "ssh"])
        #expect(!reloaded.allRules.contains { $0.builtInID == "git-fallback" })
        #expect(!reloaded.allRules.contains { $0.builtInID == "ssh" })
    }

    @Test func ruleStoreClearsUserRulesWithoutTouchingBuiltIns() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        store.setUserRules([
            RequestRule(name: "x", matcher: RequestMatcher(), template: "x", kind: .unknown)
        ])
        store.setBuiltInDisabled(id: "ssh", disabled: true)
        store.clearUserRules()
        #expect(store.userRules.isEmpty)
        #expect(store.disabledBuiltInIDs == ["ssh"])  // untouched
    }

    @Test func ruleStoreEnableAllBuiltInsClearsDisabledSet() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        store.setBuiltInDisabled(id: "ssh", disabled: true)
        store.setBuiltInDisabled(id: "git-fallback", disabled: true)
        store.enableAllBuiltIns()
        #expect(store.disabledBuiltInIDs.isEmpty)
        #expect(store.allRules == RequestRule.builtIns)
    }

    @Test func ruleStoreMigratesLegacyArrayFormat() {
        // v1 schema: top-level JSON array. Loader should detect and
        // promote it to userRules with no built-ins disabled — the old
        // list keeps running first, new built-ins also take effect.
        let url = tempDir().appendingPathComponent("rules.json")
        let legacy = #"""
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy ssh override",
            "matcher": { "processName": ["ssh"] },
            "template": "legacy ssh",
            "replacesActor": false,
            "kind": "ssh",
            "isWarning": false
          }
        ]
        """#
        try! legacy.data(using: .utf8)!.write(to: url)
        let store = RequestRuleStore(fileURL: url)
        #expect(store.userRules.count == 1)
        #expect(store.userRules.first?.name == "Legacy ssh override")
        #expect(store.disabledBuiltInIDs.isEmpty)
        // Saving rewrites the file in v2 format.
        store.save()
        let raw = try! String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"version\""))
        #expect(raw.contains("\"userRules\""))
    }

    @Test func userRulesEvaluatedBeforeBuiltIns() {
        // A user rule with the same predicate as a built-in must win
        // even when the built-in is also enabled.
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        let shadow = RequestRule(
            name: "Custom git override",
            matcher: RequestMatcher(processName: ["git"]),
            template: "custom git output",
            kind: .ssh
        )
        store.setUserRules([shadow])
        let chain = [ProcessNode(
            pid: 1, ppid: 1, name: "git", tty: nil,
            executablePath: nil, isVerifiedOnePasswordCLI: false
        )]
        let c = MatchContext(
            chain: chain, triggerArgv: ["git", "status"],
            cwd: nil, triggerCwd: nil, claudeSession: nil,
            pluginUpdate: nil, terminalBundleID: nil
        )
        let r = RequestRuleEngine.evaluate(rules: store.allRules, context: c)
        #expect(r?.rendered == "custom git output")
    }

    @Test func recentRequestsRingTrimsToCapacity() {
        let url = tempDir().appendingPathComponent("recent.json")
        let store = RecentRequestsStore(capacity: 3, fileURL: url)
        for i in 0..<10 {
            store.record(sampleRequest(title: "req-\(i)"))
        }
        #expect(store.requests.count == 3)
        #expect(store.requests.last?.title == "req-9")
        #expect(store.requests.first?.title == "req-7")
        let reloaded = RecentRequestsStore(capacity: 3, fileURL: url)
        #expect(reloaded.requests.map { $0.title } == ["req-7", "req-8", "req-9"])
    }

    private func sampleRequest(title: String) -> RecentRequest {
        RecentRequest(
            chainNames: ["op"], triggerArgv: ["op", "read", "op://X/Y"],
            cwd: nil, triggerCwd: nil, binaryVerified: true,
            claudeSession: nil, terminalBundleID: nil, tabTitle: nil,
            pluginRemoteURL: nil,
            title: title, subtitle: nil, kindRaw: "onePasswordCLI",
            isWarning: false, matchedRuleID: nil, matchedRuleName: nil
        )
    }
}
