import Foundation

/// Context extracted from a Claude Code session's JSONL transcript that
/// explains why a 1Password approval just appeared.
public struct ClaudeContext: Equatable {
    /// Session UUID (the JSONL file's basename).
    public let sessionID: String
    /// The most recent natural-language prompt typed by the user, if any.
    /// Excludes `!bash-input` blocks and system reminders.
    public let lastUserPrompt: String?
    /// The most recent shell command relevant to the approval — either a
    /// `<bash-input>` block the user typed (`!op item list`) or a Bash
    /// tool_use Claude initiated. Whichever matched is included verbatim.
    public let lastRelevantCommand: String?

    public init(sessionID: String, lastUserPrompt: String?, lastRelevantCommand: String?) {
        self.sessionID = sessionID
        self.lastUserPrompt = lastUserPrompt
        self.lastRelevantCommand = lastRelevantCommand
    }
}

/// Compute the JSONL project directory used by Claude Code for a given CWD.
/// Claude encodes the project path by replacing `/` with `-`.
/// e.g. `/Users/stig/git/trusthere/main` → `-Users-stig-git-trusthere-main`.
public func claudeProjectDirectory(cwd: String) -> URL {
    let hash = cwd.replacingOccurrences(of: "/", with: "-")
    let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    return base.appendingPathComponent(hash, isDirectory: true)
}

/// Look up Claude context for a process, given its CWD.
/// Returns nil when no JSONL session file can be located for that project.
public func claudeContext(forCWD cwd: String) -> ClaudeContext? {
    let dir = claudeProjectDirectory(cwd: cwd)
    guard let sessionFile = mostRecentSessionFile(in: dir) else { return nil }
    guard let tail = readTail(of: sessionFile, maxBytes: 64 * 1024) else { return nil }
    let sessionID = (sessionFile.lastPathComponent as NSString).deletingPathExtension
    return parseClaudeContext(jsonlTail: tail, sessionID: sessionID)
}

/// Pure helper exposed for tests: parse a JSONL tail blob and produce a
/// ClaudeContext by walking the records from newest to oldest.
public func parseClaudeContext(jsonlTail: String, sessionID: String) -> ClaudeContext? {
    let lines = jsonlTail.split(separator: "\n", omittingEmptySubsequences: true)
    // Skip the first line — when we tail-read a file at an offset, the leading
    // line is almost certainly truncated and won't parse cleanly.
    let parseable = lines.dropFirst()

    var lastPrompt: String? = nil
    var lastCommand: String? = nil

    // Walk newest-first.
    for line in parseable.reversed() {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        let type = obj["type"] as? String

        // User-typed text or `!bash-input` blocks.
        if type == "user",
           let message = obj["message"] as? [String: Any],
           message["role"] as? String == "user" {
            let text = extractUserText(message: message)
            if let text = text {
                if lastCommand == nil, let cmd = bashInputCommand(in: text) {
                    lastCommand = cmd
                } else if lastPrompt == nil, isNaturalLanguage(text) {
                    lastPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Claude-initiated Bash tool calls.
        if lastCommand == nil,
           type == "assistant",
           let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]],
           let first = content.first,
           first["type"] as? String == "tool_use",
           first["name"] as? String == "Bash",
           let input = first["input"] as? [String: Any],
           let command = input["command"] as? String,
           isRelevantCommand(command) {
            lastCommand = command
        }

        if lastPrompt != nil && lastCommand != nil { break }
    }

    if lastPrompt == nil && lastCommand == nil { return nil }
    return ClaudeContext(
        sessionID: sessionID,
        lastUserPrompt: lastPrompt.map { truncate($0) },
        lastRelevantCommand: lastCommand.map { truncate($0) }
    )
}

// MARK: - Private helpers

private func mostRecentSessionFile(in dir: URL) -> URL? {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    let jsonl = urls.filter { $0.pathExtension == "jsonl" }
    return jsonl.max(by: { lhs, rhs in
        let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return l < r
    })
}

private func readTail(of url: URL, maxBytes: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    do {
        let size = try handle.seekToEnd()
        let readSize = min(size, UInt64(maxBytes))
        let offset = size - readSize
        try handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: Int(readSize))
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

/// Pull text out of a user message — content may be a String or a [content blocks] array.
private func extractUserText(message: [String: Any]) -> String? {
    if let s = message["content"] as? String { return s }
    if let arr = message["content"] as? [[String: Any]] {
        for block in arr where (block["type"] as? String) == "text" {
            if let t = block["text"] as? String { return t }
        }
    }
    return nil
}

/// Extract a `<bash-input>...</bash-input>` payload, if present. This is how
/// Claude Code records the literal command when the user types `!cmd` in the
/// prompt — exactly what we want to surface as the trigger.
func bashInputCommand(in text: String) -> String? {
    guard let openRange = text.range(of: "<bash-input>"),
          let closeRange = text.range(of: "</bash-input>"),
          openRange.upperBound <= closeRange.lowerBound else { return nil }
    let inner = String(text[openRange.upperBound..<closeRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !inner.isEmpty, isRelevantCommand(inner) else { return nil }
    return inner
}

/// True iff a string mentions a command that could plausibly trigger a
/// 1Password approval — used to filter out irrelevant bash blocks.
func isRelevantCommand(_ cmd: String) -> Bool {
    let lc = cmd.lowercased()
    return lc.range(of: #"(^|\s|/)op\s"#, options: .regularExpression) != nil
        || lc.range(of: #"(^|\s|/)ssh\s"#, options: .regularExpression) != nil
        || lc.range(of: #"(^|\s|/)git\s"#, options: .regularExpression) != nil
        || lc.range(of: #"(^|\s|/)scp\s"#, options: .regularExpression) != nil
        || lc.range(of: #"(^|\s|/)rsync\s"#, options: .regularExpression) != nil
}

/// True if the text looks like a natural-language prompt rather than
/// a `<bash-input>` capture, a system reminder, or a structured envelope.
private func isNaturalLanguage(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return false }
    if t.hasPrefix("<bash-input>") { return false }
    if t.hasPrefix("<bash-stdout>") { return false }
    if t.hasPrefix("<bash-stderr>") { return false }
    if t.hasPrefix("<system-reminder>") { return false }
    if t.hasPrefix("<local-command-caveat>") { return false }
    if t.hasPrefix("<command-name>") { return false }
    return true
}

private func truncate(_ s: String, max: Int = 160) -> String {
    let clean = s.replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
    if clean.count <= max { return clean }
    return clean.prefix(max - 1) + "…"
}

// MARK: - Claude plugin update detection

/// Marker for a `git` operation that Claude Code initiated in the background
/// to refresh a plugin/marketplace repository under `~/.claude/plugins/`.
/// Such fetches are housekeeping — the user didn't ask for them — so we
/// label them distinctly so the user knows what 1Password is asking about.
public struct ClaudePluginUpdate: Equatable {
    /// Remote URL from the plugin repo's `.git/config`
    /// (e.g. `git@github.com:cloudflare/skills.git`).
    public let remoteURL: String
    /// `source.repo` from `known_marketplaces.json` when the install
    /// directory matched a known marketplace entry (e.g. `cloudflare/skills`).
    /// Nil when the lookup failed or the file is absent.
    public let repo: String?
    /// `source.source` from `known_marketplaces.json` — currently always
    /// `"github"` in observed Claude installs, but treated as opaque.
    public let sourceType: String?
    /// Top-level key from `known_marketplaces.json` (e.g. `cloudflare`,
    /// `sunstone-plugins`). Surfaced as context but not currently shown
    /// in any default rule.
    public let marketplaceName: String?

    public init(
        remoteURL: String,
        repo: String? = nil,
        sourceType: String? = nil,
        marketplaceName: String? = nil
    ) {
        self.remoteURL = remoteURL
        self.repo = repo
        self.sourceType = sourceType
        self.marketplaceName = marketplaceName
    }
}

/// One entry from `~/.claude/plugins/known_marketplaces.json`. Decoded
/// leniently — unknown fields (e.g. `lastUpdated`, `autoUpdate`) are
/// ignored and a malformed entry just falls out of the lookup.
public struct KnownMarketplace: Codable, Equatable {
    public let installLocation: String
    public let source: SourceInfo

    public struct SourceInfo: Codable, Equatable {
        public let source: String
        public let repo: String?

        public init(source: String, repo: String?) {
            self.source = source
            self.repo = repo
        }
    }

    public init(installLocation: String, source: SourceInfo) {
        self.installLocation = installLocation
        self.source = source
    }
}

/// Look up plugin-update info for a CWD. Returns nil unless the CWD lives
/// inside `~/.claude/plugins/` AND we can locate and parse a `.git/config`
/// at some directory between the CWD and the plugins root. When the resolved
/// repo root matches an `installLocation` in `known_marketplaces.json`, the
/// returned struct also carries the structured `repo` / `sourceType` fields.
public func claudePluginUpdate(forCWD cwd: String?) -> ClaudePluginUpdate? {
    guard let cwd = cwd else { return nil }
    let pluginsBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/plugins").path
    let marketplacesURL = URL(fileURLWithPath: pluginsBase)
        .appendingPathComponent("known_marketplaces.json")
    return resolveClaudePluginUpdate(
        forCWD: cwd,
        pluginsBase: pluginsBase,
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
        knownMarketplaces: loadKnownMarketplaces(at: marketplacesURL)
    )
}

/// Pure resolver — every disk dependency injected. The real entry point
/// `claudePluginUpdate(forCWD:)` is a thin wrapper that fills these in
/// from the live filesystem.
public func resolveClaudePluginUpdate(
    forCWD cwd: String,
    pluginsBase: String,
    fileExists: (String) -> Bool,
    readFile: (String) -> String?,
    knownMarketplaces: [String: KnownMarketplace]?
) -> ClaudePluginUpdate? {
    guard let repoRoot = pluginRepoRoot(
        cwd: cwd, pluginsBase: pluginsBase, fileExists: fileExists
    ) else { return nil }
    let configPath = (repoRoot as NSString).appendingPathComponent(".git/config")
    guard let content = readFile(configPath),
          let url = parseGitOriginURL(gitConfig: content) else { return nil }
    let entry = knownMarketplaces?.first { $0.value.installLocation == repoRoot }
    return ClaudePluginUpdate(
        remoteURL: url,
        repo: entry?.value.source.repo,
        sourceType: entry?.value.source.source,
        marketplaceName: entry?.key
    )
}

/// Decode `known_marketplaces.json`. Returns nil when the file is missing
/// or malformed — callers fall back to just the `.git/config` URL.
public func loadKnownMarketplaces(at url: URL) -> [String: KnownMarketplace]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode([String: KnownMarketplace].self, from: data)
}

/// Walk up from `cwd` toward `~/.claude/plugins/` looking for the first
/// directory containing `.git/config`. Returns nil if `cwd` isn't inside
/// the plugins tree, or if no `.git` ancestor was found before escaping it.
public func claudePluginRepoRoot(forCWD cwd: String) -> String? {
    let pluginsBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/plugins", isDirectory: true)
        .path
    return pluginRepoRoot(cwd: cwd, pluginsBase: pluginsBase, fileExists: { path in
        FileManager.default.fileExists(atPath: path)
    })
}

/// Pure helper exposed for tests: walks up from `cwd` until it either finds
/// a directory whose `.git/config` exists (per `fileExists`) or escapes the
/// `pluginsBase` prefix.
func pluginRepoRoot(
    cwd: String,
    pluginsBase: String,
    fileExists: (String) -> Bool
) -> String? {
    guard cwd == pluginsBase || cwd.hasPrefix(pluginsBase + "/") else { return nil }
    var dir = cwd
    while dir == pluginsBase || dir.hasPrefix(pluginsBase + "/") {
        let configPath = (dir as NSString).appendingPathComponent(".git/config")
        if fileExists(configPath) { return dir }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { break }
        dir = parent
    }
    return nil
}

/// Parse a git config blob and return the `[remote "origin"] url` value,
/// or nil if not present. Tolerant of whitespace and section ordering;
/// understands both quoted and unquoted subsection headers
/// (`[remote "origin"]` vs `[remote.origin]`).
public func parseGitOriginURL(gitConfig: String) -> String? {
    var inOriginSection = false
    for raw in gitConfig.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(raw)
        if let hash = line.firstIndex(where: { $0 == "#" || $0 == ";" }) {
            line = String(line[..<hash])
        }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("[") {
            inOriginSection =
                line == "[remote \"origin\"]"
                || line == "[remote.origin]"
            continue
        }
        guard inOriginSection else { continue }
        if let eq = line.firstIndex(of: "=") {
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "url" {
                let value = line[line.index(after: eq)...]
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
    }
    return nil
}
