import Foundation

/// Persistent shape of `rules.json` from v2 onwards. v1 was a bare
/// `[RequestRule]` array; the loader detects and migrates that format
/// (see `RequestRuleStore.load`).
public struct RulesStoreFile: Codable, Equatable {
    /// Schema version. Currently `2`. Bump when the on-disk layout
    /// changes in a backwards-incompatible way.
    public var version: Int
    /// User-authored rules. Evaluated by the engine *before* any
    /// enabled built-in — a user rule can shadow a built-in without
    /// disabling it.
    public var userRules: [RequestRule]
    /// `builtInID`s the user has unchecked in the Built-in Rules tab.
    /// Entries for retired built-ins are preserved (harmless) so a
    /// re-introduced ID stays disabled across the gap.
    public var disabledBuiltInIDs: [String]

    public init(
        version: Int = 2,
        userRules: [RequestRule] = [],
        disabledBuiltInIDs: [String] = []
    ) {
        self.version = version
        self.userRules = userRules
        self.disabledBuiltInIDs = disabledBuiltInIDs
    }
}

/// On-disk store for the user's rule configuration. Holds two pieces of
/// state — `userRules` (the editable, ordered list) and
/// `disabledBuiltInIDs` (which shipped rules the user has unchecked) —
/// and merges them with `RequestRule.builtIns` on demand via `allRules`.
///
/// Missing or unparseable files behave like a fresh install: empty
/// userRules, no disabled built-ins, all shipped rules active.
public final class RequestRuleStore {
    public private(set) var userRules: [RequestRule]
    public private(set) var disabledBuiltInIDs: Set<String>
    public let fileURL: URL

    /// Called after every persisted change. The app uses this to
    /// publish the new merged list to `OpWhoConfig.rules` so live
    /// detection picks it up without a relaunch. Tests leave the
    /// callback at its default no-op so they don't pollute global state.
    public var onRulesChanged: ([RequestRule]) -> Void = { _ in }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        let loaded = Self.load(from: self.fileURL) ?? RulesStoreFile()
        self.userRules = loaded.userRules
        self.disabledBuiltInIDs = Set(loaded.disabledBuiltInIDs)
    }

    /// Merged view used by the engine. User rules run first (so they
    /// can shadow built-ins); enabled built-ins follow in their shipped
    /// order. Built-ins whose `builtInID` appears in `disabledBuiltInIDs`
    /// are dropped.
    public var allRules: [RequestRule] {
        userRules + RequestRule.builtIns.filter { rule in
            guard let id = rule.builtInID else { return true }
            return !disabledBuiltInIDs.contains(id)
        }
    }

    // MARK: - User-rule mutations

    /// Replace the user-rule list (ordered). Built-in disabled state
    /// is untouched.
    public func setUserRules(_ rules: [RequestRule]) {
        userRules = rules
        save()
    }

    /// Wipe all user-authored rules. Built-in state untouched.
    public func clearUserRules() {
        userRules = []
        save()
    }

    // MARK: - Built-in toggle

    /// Enable or disable a shipped built-in by its stable `builtInID`.
    /// Disabling removes it from `allRules`; enabling restores it.
    /// Calling with an unknown ID still updates the set (harmless and
    /// keeps the contract simple).
    public func setBuiltInDisabled(id: String, disabled: Bool) {
        if disabled {
            disabledBuiltInIDs.insert(id)
        } else {
            disabledBuiltInIDs.remove(id)
        }
        save()
    }

    /// Re-enable every built-in (clears `disabledBuiltInIDs`). Useful
    /// as a "reset" affordance in the Built-ins tab.
    public func enableAllBuiltIns() {
        disabledBuiltInIDs.removeAll()
        save()
    }

    // MARK: - Persistence

    public func save() {
        let url = fileURL
        let file = RulesStoreFile(
            version: 2,
            userRules: userRules,
            disabledBuiltInIDs: Array(disabledBuiltInIDs).sorted()
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("Failed to save rules.json: \(String(describing: error), privacy: .public)")
        }
        onRulesChanged(allRules)
    }

    public static var defaultFileURL: URL {
        appSupportDirectory().appendingPathComponent("rules.json")
    }

    /// Load `rules.json`. Tries the v2 object schema first; falls back
    /// to the v1 bare-array format and migrates by treating every entry
    /// as a user rule (with no built-ins disabled). Migration preserves
    /// each pre-existing user's prior behavior — their old list still
    /// runs first — while letting newly shipped built-ins take effect
    /// for cases the user didn't override.
    private static func load(from url: URL) -> RulesStoreFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(RulesStoreFile.self, from: data) {
            return file
        }
        if let legacy = try? decoder.decode([RequestRule].self, from: data) {
            Log.app.info("Migrating legacy rules.json (\(legacy.count, privacy: .public) rules) to v2 schema as user rules")
            return RulesStoreFile(version: 2, userRules: legacy, disabledBuiltInIDs: [])
        }
        Log.app.error("Failed to decode rules.json in any known schema; using empty config")
        return nil
    }
}

/// One stored entry in the ring buffer. Captures both the raw inputs (so
/// future reclassification or pattern mining is possible) and the snapshot
/// of what we rendered at the time.
public struct RecentRequest: Codable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date

    // Raw inputs (subset of MatchContext that's safe to serialize).
    public var chainNames: [String]
    public var triggerArgv: [String]
    public var cwd: String?
    public var triggerCwd: String?
    public var binaryVerified: Bool
    public var claudeSession: String?
    public var terminalBundleID: String?
    public var tabTitle: String?
    public var pluginRemoteURL: String?

    // Rendered snapshot at detection time.
    public var title: String
    public var subtitle: String?
    public var kindRaw: String
    public var isWarning: Bool
    public var matchedRuleID: UUID?
    public var matchedRuleName: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        chainNames: [String],
        triggerArgv: [String],
        cwd: String?,
        triggerCwd: String?,
        binaryVerified: Bool,
        claudeSession: String?,
        terminalBundleID: String?,
        tabTitle: String?,
        pluginRemoteURL: String?,
        title: String,
        subtitle: String?,
        kindRaw: String,
        isWarning: Bool,
        matchedRuleID: UUID?,
        matchedRuleName: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.chainNames = chainNames
        self.triggerArgv = triggerArgv
        self.cwd = cwd
        self.triggerCwd = triggerCwd
        self.binaryVerified = binaryVerified
        self.claudeSession = claudeSession
        self.terminalBundleID = terminalBundleID
        self.tabTitle = tabTitle
        self.pluginRemoteURL = pluginRemoteURL
        self.title = title
        self.subtitle = subtitle
        self.kindRaw = kindRaw
        self.isWarning = isWarning
        self.matchedRuleID = matchedRuleID
        self.matchedRuleName = matchedRuleName
    }
}

/// Ring buffer of the last N detected requests, persisted as JSON so the
/// data survives app restarts (and is greppable from the command line).
public final class RecentRequestsStore {
    public let capacity: Int
    public let fileURL: URL
    public private(set) var requests: [RecentRequest] = []

    public init(capacity: Int = 20, fileURL: URL? = nil) {
        self.capacity = capacity
        self.fileURL = fileURL ?? Self.defaultFileURL
        if let loaded = Self.load(from: self.fileURL) {
            self.requests = Array(loaded.suffix(capacity))
        }
    }

    /// Append a new entry, trim to capacity (newest last), and persist.
    public func record(_ request: RecentRequest) {
        requests.append(request)
        if requests.count > capacity {
            requests.removeFirst(requests.count - capacity)
        }
        save()
    }

    public func clear() {
        requests.removeAll()
        save()
    }

    private func save() {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(requests)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("Failed to save recent-requests.json: \(String(describing: error), privacy: .public)")
        }
    }

    public static var defaultFileURL: URL {
        appSupportDirectory().appendingPathComponent("recent-requests.json")
    }

    private static func load(from url: URL) -> [RecentRequest]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([RecentRequest].self, from: data)
        } catch {
            Log.app.error("Failed to decode recent-requests.json: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Resolve `~/Library/Application Support/com.stigbakken.op-who`.
/// Sandboxed builds get a container-specific path; ad-hoc builds land in
/// the user's regular Application Support tree. Either way the directory
/// is created on first write.
public func appSupportDirectory() -> URL {
    let fm = FileManager.default
    let base = (try? fm.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )) ?? fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("com.stigbakken.op-who", isDirectory: true)
}
