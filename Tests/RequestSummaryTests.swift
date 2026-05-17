import Testing
import Darwin
@testable import OpWhoLib

private func node(_ name: String, pid: pid_t = 100, verified: Bool = false) -> ProcessNode {
    ProcessNode(
        pid: pid, ppid: 1, name: name, tty: nil,
        executablePath: nil, isVerifiedOnePasswordCLI: verified
    )
}

@Suite("RequestSummary")
struct RequestSummaryTests {

    @Test func opVerifiedFromClaude() {
        let chain = [node("op", verified: true), node("claude"), node("zsh")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil,
            claudeSession: "op-who",
            terminalBundleID: "com.googlecode.iterm2",
            cwd: "~/git/stigsb/op-who"
        )
        #expect(s.kind == .onePasswordCLI)
        #expect(s.title.contains("Claude Code"))
        #expect(s.title.contains("op-who"))
        #expect(s.title.contains("1Password CLI"))
        #expect(s.subtitle?.contains("iTerm") == true)
        #expect(s.subtitle?.contains("~/git/stigsb/op-who") == true)
        #expect(s.isWarning == false)
    }

    @Test func unverifiedOpRaisesWarning() {
        let chain = [node("op", verified: false), node("bash")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil, claudeSession: nil,
            terminalBundleID: "com.apple.Terminal", cwd: nil
        )
        #expect(s.kind == .unverifiedOp)
        #expect(s.isWarning == true)
        #expect(s.title.contains("unverified"))
    }

    @Test func sshFromGit() {
        let chain = [node("git"), node("zsh")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil, claudeSession: nil,
            terminalBundleID: "com.googlecode.iterm2",
            cwd: "/Users/x/proj"
        )
        #expect(s.kind == .ssh)
        #expect(s.title.contains("SSH key"))
        #expect(s.title.contains("git"))
    }

    @Test func sshDirect() {
        let chain = [node("ssh"), node("bash")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.kind == .ssh)
        #expect(s.title.contains("SSH key"))
        // For plain `ssh`, we don't tack on a "via" qualifier.
        #expect(s.title.contains("via") == false)
    }

    @Test func opSshSignFromCommitSigning() {
        let chain = [node("op-ssh-sign"), node("git"), node("zsh")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil, claudeSession: nil,
            terminalBundleID: "com.googlecode.iterm2", cwd: nil
        )
        #expect(s.kind == .ssh)
        #expect(s.title.contains("signing"))
        #expect(s.isWarning == false)
    }

    @Test func sshKeygenSigning() {
        let chain = [node("ssh-keygen"), node("git"), node("bash")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.kind == .ssh)
        #expect(s.title.contains("signing"))
    }

    @Test func operationDisplayCollapsesCommitSigningArgv() {
        let chain = [node("op-ssh-sign"), node("git"), node("zsh")]
        let argv = [
            "/Applications/1Password.app/Contents/MacOS/op-ssh-sign",
            "-Y", "sign", "-n", "git",
            "-f", "/var/folders/jk/.../.git_signing_key_tmpXXXX",
            "-U", "/var/folders/jk/.../.git_signing_buffer_tmpYYYY",
        ]
        let text = operationDisplay(argv: argv, chain: chain, cwd: "~/git/stigsb/op-who")
        #expect(text == "signing a commit in ~/git/stigsb/op-who")
    }

    @Test func operationDisplayCommitSigningWithoutCwd() {
        let chain = [node("ssh-keygen"), node("git"), node("zsh")]
        let argv = ["/usr/bin/ssh-keygen", "-Y", "sign", "-n", "git", "-f", "/tmp/k"]
        let text = operationDisplay(argv: argv, chain: chain, cwd: nil)
        #expect(text == "signing a commit")
    }

    @Test func operationDisplayKeepsNonSigningSshKeygenArgv() {
        // ssh-keygen used for keygen / fingerprint / etc. should NOT be
        // collapsed — those are real argv worth showing.
        let chain = [node("ssh-keygen"), node("zsh")]
        let argv = ["/usr/bin/ssh-keygen", "-l", "-f", "~/.ssh/id_rsa.pub"]
        let text = operationDisplay(argv: argv, chain: chain, cwd: nil)
        #expect(text.contains("-l"))
        #expect(text.contains("id_rsa.pub"))
    }

    @Test func pluginUpdateTitleOverridesNormalSummary() {
        let chain = [node("git"), node("node"), node("claude")]
        let update = ClaudePluginUpdate(
            remoteURL: "git@github.com:cloudflare/skills.git",
            repo: "cloudflare/skills",
            sourceType: "github",
            marketplaceName: "cloudflare"
        )
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil,
            claudeSession: "op-who",
            terminalBundleID: "com.googlecode.iterm2",
            cwd: "~/.claude/plugins/marketplaces/cloudflare",
            pluginUpdate: update
        )
        #expect(s.kind == .ssh)
        #expect(s.title == "Claude plugin update check for cloudflare/skills (github)")
        #expect(s.isWarning == false)
        #expect(s.subtitle?.contains("iTerm") == true)
        #expect(s.subtitle?.contains("~/.claude/plugins/marketplaces/cloudflare") == true)
    }

    @Test func actorPrefersClaudeOverShell() {
        let chain = [node("op", verified: true), node("zsh"), node("claude")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil,
            claudeSession: "test",
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.title.starts(with: "Claude Code"))
    }

    @Test func actorFallsBackToShell() {
        let chain = [node("op", verified: true), node("zsh")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.title.contains("zsh shell"))
    }

    @Test func actorFallsBackToTerminalApp() {
        let chain = [node("op", verified: true)]
        let s = makeRequestSummary(
            chain: chain, tabTitle: nil, claudeSession: nil,
            terminalBundleID: "com.mitchellh.ghostty",
            cwd: nil
        )
        #expect(s.title.contains("Ghostty"))
    }

    @Test func emptyChainReturnsUnknown() {
        let s = makeRequestSummary(
            chain: [], tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.kind == .unknown)
        #expect(s.isWarning == true)
    }

    @Test func genericTabTitleIsIgnored() {
        // A typical Terminal.app default title — should not become the actor.
        let chain = [node("op", verified: true), node("zsh")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: "stig@laptop: ~/code",
            claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.title.contains("Terminal tab") == false)
        #expect(s.title.contains("zsh shell"))
    }

    @Test func cmuxItemPlaceholderTabTitleIgnored() {
        // cmux's AX layer reports "Item-0" / "Item-N" placeholder titles
        // when its scripting-surface lookup hasn't (or can't) resolved the
        // real workspace name. Without the Item-N filter this rendered as
        // "Claude Code in cmux workspace ‘Item-0’" in the wild.
        let chain = [node("ssh"), node("claude"), node("zsh")]
        let s = makeRequestSummary(
            chain: chain,
            tabTitle: "Item-0",
            claudeSession: "op-who",
            terminalBundleID: "com.cmuxterm.app",
            cwd: nil
        )
        #expect(!s.title.contains("Item-0"))
        #expect(!s.title.contains("workspace"))
        #expect(s.title.contains("Claude Code"))
    }

    @Test func itemPlaceholderRespectsExactPattern() {
        // Real names that happen to start with "Item" but don't match
        // the Item-<digits> shape should still pass through as actors.
        let chain = [node("op", verified: true), node("zsh")]
        let s = makeRequestSummary(
            chain: chain,
            tabTitle: "Item Bank",
            claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.title.contains("Item Bank"))
    }

    @Test func customTabTitleBecomesActor() {
        let chain = [node("op", verified: true), node("zsh")]
        let s = makeRequestSummary(
            chain: chain, tabTitle: "deploy",
            claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.title.contains("deploy"))
    }

    @Test func humanTerminalNameKnown() {
        #expect(humanTerminalName(bundleID: "com.apple.Terminal") == "Terminal")
        #expect(humanTerminalName(bundleID: "com.googlecode.iterm2") == "iTerm")
        #expect(humanTerminalName(bundleID: "com.mitchellh.ghostty") == "Ghostty")
        #expect(humanTerminalName(bundleID: "dev.warp.Warp-Stable") == "Warp")
    }

    @Test func humanTerminalNameUnknownReturnsRaw() {
        #expect(humanTerminalName(bundleID: "com.example.NewTerm") == "com.example.NewTerm")
    }

    @Test func humanTerminalNameNilReturnsNil() {
        #expect(humanTerminalName(bundleID: nil) == nil)
    }

    // MARK: - argv parsing

    @Test func opReadIncludesURI() {
        let chain = [node("op", verified: true)]
        let s = makeRequestSummary(
            chain: chain,
            triggerArgv: ["/usr/local/bin/op", "read", "op://DevOps/some-secret/credential"],
            tabTitle: "sunstone-cms", claudeSession: "sunstone-cms",
            terminalBundleID: "io.cmux", cwd: nil
        )
        #expect(s.title.contains("read op://DevOps/some-secret/credential"))
        #expect(s.title.contains("Claude Code"))
        #expect(s.title.contains("cmux workspace ‘sunstone-cms’"))
    }

    @Test func opSigninPhrase() {
        let chain = [node("op", verified: true)]
        let s = makeRequestSummary(
            chain: chain, triggerArgv: ["op", "signin"],
            tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.title.contains("sign in to 1Password"))
    }

    @Test func opItemGetPhrase() {
        let chain = [node("op", verified: true)]
        let s = makeRequestSummary(
            chain: chain, triggerArgv: ["op", "item", "get", "GitHub"],
            tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.title.contains("op item get"))
    }

    @Test func gitFetchSubcommand() {
        let chain = [node("git"), node("zsh")]
        let s = makeRequestSummary(
            chain: chain,
            triggerArgv: ["git", "fetch", "origin"],
            tabTitle: "data-platform", claudeSession: nil,
            terminalBundleID: "io.cmux", cwd: nil
        )
        #expect(s.kind == .ssh)
        #expect(s.title.contains("git fetch"))
        #expect(s.title.contains("cmux workspace"))
        #expect(s.title.contains("data-platform"))
    }

    @Test func gitFlagsSkipped() {
        // git -C /tmp -c color.ui=false push origin → "push"
        let chain = [node("git")]
        let s = makeRequestSummary(
            chain: chain,
            triggerArgv: ["git", "-C", "/tmp", "-c", "color.ui=false", "push", "origin"],
            tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil
        )
        #expect(s.title.contains("git push"))
    }

    // MARK: - cmux + Claude phrasing

    @Test func cmuxWorkspaceWithoutClaude() {
        let chain = [node("op", verified: true), node("zsh")]
        let s = makeRequestSummary(
            chain: chain, triggerArgv: ["op", "read", "op://Foo/Bar"],
            tabTitle: "my-workspace", claudeSession: nil,
            terminalBundleID: "io.cmux", cwd: nil
        )
        #expect(s.title.starts(with: "cmux workspace ‘my-workspace’"))
    }

    @Test func claudeInITermTabPhrasing() {
        let chain = [node("op", verified: true), node("claude")]
        let s = makeRequestSummary(
            chain: chain, triggerArgv: ["op", "read", "op://X/Y"],
            tabTitle: "deploy",
            claudeSession: "trusthere",
            terminalBundleID: "com.googlecode.iterm2",
            cwd: nil
        )
        #expect(s.title.contains("Claude Code in iTerm tab ‘deploy’"))
        // claudeSession should still appear once in subtitle to disambiguate.
        #expect(s.subtitle?.contains("session: trusthere") == true)
    }

    @Test func cmuxWithGenericTabTitleFallsBack() {
        // Default-y tab title shouldn't be promoted to a workspace name.
        let chain = [node("op", verified: true), node("zsh")]
        let s = makeRequestSummary(
            chain: chain, triggerArgv: nil ?? [],
            tabTitle: "zsh", claudeSession: nil,
            terminalBundleID: "io.cmux", cwd: nil
        )
        #expect(s.title.contains("workspace") == false)
        #expect(s.title.contains("zsh shell"))
    }

    // MARK: - argv parser

    @Test func parseEnvFromRaw() {
        // argc=1, exec_path, padding, argv[0], envp[0..2]
        var blob: [UInt8] = [1, 0, 0, 0]
        blob.append(contentsOf: Array("/bin/zsh".utf8)); blob.append(0)
        blob.append(contentsOf: [0, 0])
        blob.append(contentsOf: Array("zsh".utf8)); blob.append(0)
        blob.append(contentsOf: Array("PATH=/usr/bin".utf8)); blob.append(0)
        blob.append(contentsOf: Array("CMUX_WORKSPACE_ID=ws-abc".utf8)); blob.append(0)
        blob.append(contentsOf: Array("CMUX_TAB_ID=tab-7".utf8)); blob.append(0)
        blob.append(0)  // terminator

        let env = ProcessTree.parseEnvironment(
            rawProcargs2: blob,
            names: ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "MISSING"]
        )
        #expect(env["CMUX_WORKSPACE_ID"] == "ws-abc")
        #expect(env["CMUX_TAB_ID"] == "tab-7")
        #expect(env["MISSING"] == nil)
        #expect(env["PATH"] == nil)  // not requested
    }

    @Test func parseArgvFromRaw() {
        // Synthesize a minimal procargs2 blob: argc=3, exec_path, argv[0..2].
        var blob: [UInt8] = []
        // argc = 3, little-endian
        blob.append(contentsOf: [3, 0, 0, 0])
        // exec_path
        blob.append(contentsOf: Array("/usr/local/bin/op".utf8))
        blob.append(0)
        // padding NULs (simulate alignment)
        blob.append(contentsOf: [0, 0, 0])
        // argv[0]
        blob.append(contentsOf: Array("op".utf8)); blob.append(0)
        // argv[1]
        blob.append(contentsOf: Array("read".utf8)); blob.append(0)
        // argv[2]
        blob.append(contentsOf: Array("op://Foo/Bar".utf8)); blob.append(0)
        // Junk env afterwards (must not be returned)
        blob.append(contentsOf: Array("PATH=/usr/bin".utf8)); blob.append(0)

        let argv = ProcessTree.parseArgv(rawProcargs2: blob)
        #expect(argv == ["op", "read", "op://Foo/Bar"])
    }

    @Test func describeOpInvocationParsesURI() {
        #expect(
            describeOpInvocation(argv: ["/opt/homebrew/bin/op", "read", "op://Dev/Secret/cred"]) ==
            "read op://Dev/Secret/cred"
        )
    }

    @Test func describeOpInvocationNonOpReturnsNil() {
        #expect(describeOpInvocation(argv: ["bash", "-c", "echo hi"]) == nil)
    }

    @Test func describeGitInvocationSkipsFlags() {
        #expect(describeGitInvocation(argv: ["git", "-C", "/x", "fetch"]) == "fetch")
        #expect(describeGitInvocation(argv: ["git", "--git-dir=/x", "pull"]) == "pull")
        #expect(describeGitInvocation(argv: ["git", "push"]) == "push")
    }

    @Test func isRemoteGitTrueForNetworkSubcommands() {
        for sub in ["fetch", "pull", "push", "clone", "ls-remote", "archive", "submodule"] {
            #expect(isRemoteGitSubcommand(argv: ["git", sub]),
                    "expected \(sub) to be considered remote")
        }
    }

    @Test func isRemoteGitFalseForLocalSubcommands() {
        for sub in ["show", "log", "status", "diff", "commit", "add", "rm", "mv",
                    "branch", "tag", "checkout", "reset", "stash", "init", "config"] {
            #expect(!isRemoteGitSubcommand(argv: ["git", sub]),
                    "expected \(sub) to be local-only")
        }
    }

    @Test func isRemoteGitHandlesGlobalFlags() {
        #expect(isRemoteGitSubcommand(argv: ["git", "-C", "/x", "fetch", "origin"]))
        #expect(!isRemoteGitSubcommand(argv: ["git", "-c", "color.ui=false", "show", "HEAD"]))
    }

    @Test func isRemoteGitFalseForNonGit() {
        #expect(!isRemoteGitSubcommand(argv: ["bash", "-c", "fetch"]))
        #expect(!isRemoteGitSubcommand(argv: []))
    }

    // MARK: - Driver detection

    @Test func driverIsClaudeWhenSessionPresent() {
        let chain = [node("op"), node("zsh"), node("claude")]
        let info = driverDescription(chain: chain, claudeSession: "main")
        #expect(info.text == "Claude Code")
        #expect(info.kind == .claude)
        #expect(info.bundleID == nil)
    }

    @Test func driverIsVSCodeWhenInChain() {
        let chain = [node("op"), node("zsh"), node("Code")]
        let info = driverDescription(chain: chain, claudeSession: nil)
        #expect(info.text == "VS Code")
        #expect(info.kind == .editor)
        #expect(info.bundleID == "com.microsoft.VSCode")
    }

    @Test func driverIsVimWhenInChain() {
        let chain = [node("op"), node("vim")]
        let info = driverDescription(chain: chain, claudeSession: nil)
        #expect(info.text == "vim")
        #expect(info.kind == .editor)
        #expect(info.bundleID == nil)  // CLI editor, no bundle
    }

    @Test func driverIsCursorMatchedByHelper() {
        let chain = [node("op"), node("zsh"), node("Cursor Helper")]
        let info = driverDescription(chain: chain, claudeSession: nil)
        #expect(info.text == "Cursor")
        #expect(info.kind == .editor)
        #expect(info.bundleID != nil)
    }

    @Test func driverIsShellWhenNoEditor() {
        let chain = [node("op"), node("zsh")]
        let info = driverDescription(chain: chain, claudeSession: nil)
        #expect(info.text == "zsh")
        #expect(info.kind == .shell)
    }

    @Test func driverIsOtherFallback() {
        let chain = [node("op"), node("unknown-launcher")]
        let info = driverDescription(chain: chain, claudeSession: nil)
        #expect(info.text == "unknown-launcher")
        #expect(info.kind == .other)
    }

    @Test func editorBeatsShellWhenBothPresent() {
        let chain = [node("op"), node("zsh"), node("Code")]
        let info = driverDescription(chain: chain, claudeSession: nil)
        #expect(info.text == "VS Code")
        #expect(info.kind == .editor)
    }

    // MARK: - Operation display

    @Test func operationStripsExecPathFromArgv() {
        let chain = [node("op", verified: true)]
        #expect(operationDisplay(argv: ["/opt/homebrew/bin/op", "item", "list"], chain: chain)
                == "op item list")
    }

    @Test func operationFallsBackToChainNameOnEmptyArgv() {
        let chain = [node("op", verified: true), node("zsh")]
        #expect(operationDisplay(argv: [], chain: chain) == "op")
    }
}
