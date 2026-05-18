import Testing
import Foundation
@testable import OpWhoLib

@Suite("ClaudeContext parser")
struct ClaudeContextTests {

    /// Build a JSONL-style multi-line blob from individual record dicts.
    private func jsonl(_ records: [[String: Any]]) -> String {
        // Prefix a junk line — real tail-reads land mid-record, so the parser
        // must skip the first line. Our test data needs to model that.
        var lines = ["NOT-JSON-PARTIAL-LINE"]
        for rec in records {
            let data = try! JSONSerialization.data(withJSONObject: rec)
            lines.append(String(data: data, encoding: .utf8)!)
        }
        return lines.joined(separator: "\n")
    }

    @Test func extractsBashInputFromUserMessage() {
        let blob = jsonl([
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "<bash-input>op vault list</bash-input>\n<bash-stdout>ID NAME</bash-stdout>",
                ],
            ]
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "test")
        #expect(ctx?.lastRelevantCommand == "op vault list")
    }

    @Test func extractsClaudeBashToolUse() {
        let blob = jsonl([
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use",
                        "name": "Bash",
                        "input": ["command": "op item list"],
                    ]],
                ],
            ]
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastRelevantCommand == "op item list")
    }

    @Test func extractsNaturalLanguagePrompt() {
        let blob = jsonl([
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "please run op item list and tell me the count",
                ],
            ]
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastUserPrompt?.starts(with: "please run op item list") == true)
    }

    @Test func skipsSystemReminders() {
        let blob = jsonl([
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "<system-reminder>tasks getting stale</system-reminder>",
                ],
            ]
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastUserPrompt == nil)
    }

    @Test func picksNewestRelevantCommand() {
        // Older command is git fetch, newer is op item list — newer wins.
        let blob = jsonl([
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use", "name": "Bash",
                        "input": ["command": "git fetch origin"],
                    ]],
                ],
            ],
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "<bash-input>op item list</bash-input>",
                ],
            ],
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastRelevantCommand == "op item list")
    }

    @Test func filtersIrrelevantCommands() {
        // No op/ssh/git here — should return no command.
        let blob = jsonl([
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "<bash-input>ls -la</bash-input>",
                ],
            ],
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastRelevantCommand == nil)
    }

    @Test func projectDirectoryEncoding() {
        let dir = claudeProjectDirectory(cwd: "/Users/stig/git/trusthere/main")
        #expect(dir.path.hasSuffix("/.claude/projects/-Users-stig-git-trusthere-main"))
    }

    @Test func bashInputCommandHelper() {
        #expect(bashInputCommand(in: "<bash-input>op signin</bash-input>") == "op signin")
        #expect(bashInputCommand(in: "no markers") == nil)
        #expect(bashInputCommand(in: "<bash-input>ls</bash-input>") == nil)  // not relevant
    }

    @Test func relevantCommandRegex() {
        #expect(isRelevantCommand("op item list"))
        #expect(isRelevantCommand("/usr/local/bin/op vault list"))
        #expect(isRelevantCommand("git push origin main"))
        #expect(isRelevantCommand("ssh user@host"))
        #expect(!isRelevantCommand("opentemplate run"))   // not "op " as token
        #expect(!isRelevantCommand("ls -la"))
        #expect(!isRelevantCommand("echo opacity"))
    }

    @Test func parsesQuotedRemoteOriginURL() {
        let cfg = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = git@github.com:cloudflare/skills.git
        \tfetch = +refs/heads/main:refs/remotes/origin/main
        """
        #expect(parseGitOriginURL(gitConfig: cfg) == "git@github.com:cloudflare/skills.git")
    }

    @Test func parsesHTTPSRemoteOriginURL() {
        let cfg = """
        [remote "origin"]
        \turl = https://github.com/tomasz-tomczyk/crit.git
        """
        #expect(parseGitOriginURL(gitConfig: cfg) == "https://github.com/tomasz-tomczyk/crit.git")
    }

    @Test func returnsNilWhenNoOriginRemote() {
        let cfg = """
        [core]
        \trepositoryformatversion = 0
        [remote "upstream"]
        \turl = git@github.com:foo/bar.git
        """
        #expect(parseGitOriginURL(gitConfig: cfg) == nil)
    }

    @Test func ignoresCommentsAndOtherSections() {
        let cfg = """
        # comment
        [branch "main"]
        \tremote = origin
        [remote "origin"]
        \t; the real url
        \turl = git@github.com:org/repo.git
        """
        #expect(parseGitOriginURL(gitConfig: cfg) == "git@github.com:org/repo.git")
    }

    @Test func pluginRepoRootFindsClosestGit() {
        // Synthetic: cwd is two levels inside the marketplace repo. The
        // repo root sits between cwd and the plugins base.
        let base = "/Users/x/.claude/plugins"
        let cwd = "\(base)/marketplaces/crit/skills/foo"
        let gitConfigs: Set<String> = [
            "\(base)/marketplaces/crit/.git/config",
        ]
        let root = pluginRepoRoot(
            cwd: cwd, pluginsBase: base,
            fileExists: { gitConfigs.contains($0) }
        )
        #expect(root == "\(base)/marketplaces/crit")
    }

    @Test func pluginRepoRootRejectsCWDOutsidePlugins() {
        let base = "/Users/x/.claude/plugins"
        let root = pluginRepoRoot(
            cwd: "/Users/x/git/repo",
            pluginsBase: base,
            fileExists: { _ in true }
        )
        #expect(root == nil)
    }

    @Test func pluginRepoRootReturnsNilWhenNoGitFound() {
        let base = "/Users/x/.claude/plugins"
        let root = pluginRepoRoot(
            cwd: "\(base)/marketplaces/crit/skills",
            pluginsBase: base,
            fileExists: { _ in false }
        )
        #expect(root == nil)
    }

    @Test func knownMarketplacesLoaderDecodesRealSchema() {
        // Schema mirrors a real `~/.claude/plugins/known_marketplaces.json`
        // entry, including an unknown sibling field (`autoUpdate`) and the
        // optional `lastUpdated` — both must be ignored.
        let json = #"""
        {
          "cloudflare": {
            "source": { "source": "github", "repo": "cloudflare/skills" },
            "installLocation": "/Users/x/.claude/plugins/marketplaces/cloudflare",
            "lastUpdated": "2026-05-08T09:19:52.200Z"
          },
          "sunstone-plugins": {
            "source": { "source": "github", "repo": "sunstoneinstitute/claude-plugins" },
            "installLocation": "/Users/x/.claude/plugins/marketplaces/sunstone-plugins",
            "autoUpdate": true
          }
        }
        """#
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("op-who-mkt-\(UUID().uuidString).json")
        try! json.data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dict = loadKnownMarketplaces(at: tmp)
        #expect(dict?["cloudflare"]?.source.repo == "cloudflare/skills")
        #expect(dict?["sunstone-plugins"]?.installLocation
                == "/Users/x/.claude/plugins/marketplaces/sunstone-plugins")
    }

    @Test func knownMarketplacesLoaderReturnsNilForMissingFile() {
        let nowhere = URL(fileURLWithPath: "/this/path/does/not/exist.json")
        #expect(loadKnownMarketplaces(at: nowhere) == nil)
    }

    @Test func resolveEnrichesWithMarketplaceMetadata() {
        let base = "/Users/x/.claude/plugins"
        let cwd = "\(base)/marketplaces/cloudflare/skills/foo"
        let configPath = "\(base)/marketplaces/cloudflare/.git/config"
        let gitConfig = "[remote \"origin\"]\n\turl = git@github.com:cloudflare/skills.git\n"
        let mkt = [
            "cloudflare": KnownMarketplace(
                installLocation: "\(base)/marketplaces/cloudflare",
                source: .init(source: "github", repo: "cloudflare/skills")
            ),
        ]
        let result = resolveClaudePluginUpdate(
            forCWD: cwd, pluginsBase: base,
            fileExists: { $0 == configPath },
            readFile: { $0 == configPath ? gitConfig : nil },
            knownMarketplaces: mkt
        )
        #expect(result?.remoteURL == "git@github.com:cloudflare/skills.git")
        #expect(result?.repo == "cloudflare/skills")
        #expect(result?.sourceType == "github")
        #expect(result?.marketplaceName == "cloudflare")
    }

    @Test func resolveStillReturnsURLWhenMarketplacesMissing() {
        // No marketplaces dict → repo/sourceType nil but remoteURL still
        // populated from .git/config. This is the path that lets the
        // fallback rule 1b render via {plugin_remote}.
        let base = "/Users/x/.claude/plugins"
        let cwd = "\(base)/marketplaces/unknown"
        let configPath = "\(base)/marketplaces/unknown/.git/config"
        let result = resolveClaudePluginUpdate(
            forCWD: cwd, pluginsBase: base,
            fileExists: { $0 == configPath },
            readFile: { _ in "[remote \"origin\"]\n\turl = git@gitlab.com:acme/widgets.git\n" },
            knownMarketplaces: nil
        )
        #expect(result?.remoteURL == "git@gitlab.com:acme/widgets.git")
        #expect(result?.repo == nil)
        #expect(result?.sourceType == nil)
    }
}
