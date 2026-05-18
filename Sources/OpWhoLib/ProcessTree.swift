import AppKit
import Darwin
import Security

public struct ProcessNode {
    public let pid: pid_t
    public let ppid: pid_t
    public let name: String
    public let tty: String?
    public let executablePath: String?
    public let isVerifiedOnePasswordCLI: Bool

    public init(pid: pid_t, ppid: pid_t, name: String, tty: String?, executablePath: String?, isVerifiedOnePasswordCLI: Bool) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.tty = tty
        self.executablePath = executablePath
        self.isVerifiedOnePasswordCLI = isVerifiedOnePasswordCLI
    }

    public var displayName: String {
        "\(name) (\(pid))"
    }

    public var chainDisplayName: String {
        if name == "op" && !isVerifiedOnePasswordCLI {
            return "unverified op"
        }
        return name
    }
}

public struct ChainResult {
    public let chain: [ProcessNode]
    public let tty: String?
    public let terminalBundleID: String?
    public let terminalPID: pid_t?
    public let hasClaudeCode: Bool
    public let claudePID: pid_t?
}

public enum ProcessTree {

    /// 1Password's Apple Team ID. Pinned in code — never user-configurable
    /// — so a malicious app cannot expand the set of signing identities
    /// op-who treats as 1Password. Used both to gate the AX-observer
    /// attach to the 1Password app process and to verify trigger binaries
    /// claiming to be the `op` CLI.
    private static let onePasswordTeamID = "2BUA8C4S2C"

    /// `SecRequirement` text matching binaries signed by 1Password's
    /// Team ID under an Apple-issued Developer ID cert chain.
    private static let onePasswordRequirementText: String =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(onePasswordTeamID)\""

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "io.cmux",
        "com.cmux.cmux",
        "com.cmuxterm.app",
    ]

    /// Process-name prefixes for internal helpers of a terminal app. When we
    /// see one of these while walking the chain we terminate the walk and
    /// attribute it to the matching terminal bundle ID — the helper itself
    /// adds no information for the user (and on iTerm the helper name like
    /// "iTermServer-3.6.X" is truncated by macOS to 15 chars, which looks
    /// like garbage in the overlay).
    private static let terminalHelperPrefixes: [(prefix: String, bundleID: String)] = [
        ("iTermServer", "com.googlecode.iterm2"),
    ]

    private static func matchTerminalHelper(name: String) -> String? {
        for (prefix, bid) in terminalHelperPrefixes where name.hasPrefix(prefix) {
            return bid
        }
        return nil
    }

    /// Find all running processes named "op".
    public static func findOpProcesses() -> [ProcessNode] {
        return allProcesses()
            .filter { $0.name == "op" }
            .map(verifiedOpNode)
    }

    /// Find running processes that are likely SSH agent clients.
    public static func findSSHAgentClients() -> [ProcessNode] {
        let sshCommands: Set<String> = ["ssh", "git", "scp", "sftp", "rsync"]
        return allProcesses().filter { sshCommands.contains($0.name) }
    }

    /// Find all trigger processes (op + SSH clients + SSH signers) in a single
    /// process scan. Does NOT perform signature verification — that is deferred
    /// to chain building so it doesn't block initial detection.
    ///
    /// `op-ssh-sign` is 1Password's bundled commit-signing helper (set as
    /// `gpg.ssh.program` when users wire 1Password into git's SSH signing).
    /// `ssh-keygen` is the upstream equivalent used by git when no custom
    /// program is configured. Without either in this list, commit signing
    /// would silently fall off op-who's radar — its trigger process never
    /// reaches a candidate slot, and the surrounding `git commit` is dropped
    /// as a non-network git subcommand.
    public static func findTriggerProcesses() -> [ProcessNode] {
        let triggerNames: Set<String> = [
            "op", "ssh", "git", "scp", "sftp", "rsync",
            "ssh-keygen", "op-ssh-sign",
        ]
        return allProcesses().filter { triggerNames.contains($0.name) }
    }

    /// Walk the parent chain from a PID, stopping at Mac app processes or launchd.
    public static func buildChain(from pid: pid_t) -> ChainResult {
        let all = allProcesses()
        let lookup = Dictionary(all.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        // Build a set of PIDs that are Mac apps, mapped to their bundle IDs
        let appPIDs = macAppPIDs()

        var chain: [ProcessNode] = []
        var current = pid
        var visited = Set<pid_t>()
        var tty: String? = nil
        var terminalBundleID: String? = nil
        var terminalPID: pid_t? = nil
        var claudePID: pid_t? = nil

        while current > 0, var proc = lookup[current], !visited.contains(current) {
            visited.insert(current)

            if proc.name == "op" {
                proc = verifiedOpNode(proc)
            }

            // Stop at launchd
            if proc.name == "launchd" { break }

            // Check if this is a Mac app
            if let bundleID = appPIDs[current] {
                if terminalBundleIDs.contains(bundleID) {
                    terminalBundleID = bundleID
                    terminalPID = current
                }
                // Don't include the Mac app itself — 1Password already shows it
                break
            }

            // Check if this is a terminal-helper process (e.g. iTermServer).
            // The helper isn't an NSWorkspace app, but it stands in for one.
            if let helperBundle = Self.matchTerminalHelper(name: proc.name) {
                if terminalBundleID == nil {
                    terminalBundleID = helperBundle
                    terminalPID = current
                }
                break
            }

            // Track TTY (first one found)
            if tty == nil, let t = proc.tty {
                tty = t
            }

            // Detect Claude Code
            if proc.name == "claude" {
                claudePID = proc.pid
            }

            chain.append(proc)
            if proc.ppid == current { break }
            current = proc.ppid
        }

        // If we didn't find a "claude" process, look for a node process that's
        // running Claude Code by checking its executable path or open files
        if claudePID == nil {
            for node in chain where node.name == "node" {
                if isClaudeCodeProcess(pid: node.pid) {
                    claudePID = node.pid
                    break
                }
            }
        }

        return ChainResult(
            chain: chain,
            tty: tty,
            terminalBundleID: terminalBundleID,
            terminalPID: terminalPID,
            hasClaudeCode: claudePID != nil,
            claudePID: claudePID
        )
    }

    /// Format a process chain as a compact display string.
    public static func formatChain(_ chain: [ProcessNode]) -> String {
        chain.map { $0.chainDisplayName }.joined(separator: " \u{2192} ")
    }

    /// Detect a Claude Code session name from a claude/node process.
    ///
    /// Uses the process's CWD (via `proc_pidinfo`) and returns the last path
    /// component as the session name. The Bun-compiled `claude` binary
    /// (Homebrew install) does not keep session JSONL files open as long-lived
    /// file descriptors, so any approach that scans `lsof` output for
    /// `.claude/projects/` paths will miss them. The CWD is set to the project
    /// directory by both the Bun and Node builds, so the basename is a stable
    /// proxy for the session/project name.
    public static func claudeSessionInfo(pid: pid_t) -> String? {
        return sessionName(fromCWD: processCWD(pid: pid))
    }

    /// Pure helper: derive a session name from a CWD path.
    /// Returns nil for paths that don't carry useful session context.
    static func sessionName(fromCWD cwd: String?) -> String? {
        guard let cwd = cwd, cwd != "/", !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Return the wall-clock start time of a process, or nil if unavailable.
    public static func processStartTime(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard r == Int32(size) else { return nil }
        let secs = Double(info.pbi_start_tvsec)
        let usecs = Double(info.pbi_start_tvusec) / 1_000_000.0
        return Date(timeIntervalSince1970: secs + usecs)
    }

    /// Return the current working directory of a process, or nil.
    /// Uses proc_pidinfo for a direct kernel query (faster and more reliable
    /// than lsof, which can return stale or incorrect results in some
    /// terminal multiplexers).
    public static func processCWD(pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
        guard ret == size else { return nil }

        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                let s = String(cString: $0)
                return s.isEmpty ? nil : s
            }
        }
    }

    /// Walk a process chain and return the most meaningful CWD.
    /// The trigger process (op, ssh) often runs with CWD "/", so we prefer
    /// the first ancestor that has a real working directory.
    public static func bestCWD(chain: [ProcessNode]) -> String? {
        for node in chain {
            if let cwd = processCWD(pid: node.pid), cwd != "/" {
                return cwd
            }
        }
        // Fall back to "/" if that's all we have
        if let first = chain.first {
            return processCWD(pid: first.pid)
        }
        return nil
    }

    /// Tidy a path for display: replace $HOME with ~.
    public static func tidyPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Private

    /// Build a mapping of PID → bundle ID for all running Mac apps.
    private static func macAppPIDs() -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                result[app.processIdentifier] = bid
            }
        }
        return result
    }

    /// Check if a `node` process is actually Claude Code by looking at its args.
    private static func isClaudeCodeProcess(pid: pid_t) -> Bool {
        let raw = processArguments(pid: pid)
        return raw.contains("claude") || raw.contains("@anthropic")
    }

    private static func verifiedOpNode(_ node: ProcessNode) -> ProcessNode {
        guard node.name == "op" else { return node }

        let path = executablePath(pid: node.pid)
        return ProcessNode(
            pid: node.pid,
            ppid: node.ppid,
            name: node.name,
            tty: node.tty,
            executablePath: path,
            isVerifiedOnePasswordCLI: path.map(isSignedByOnePassword) ?? false
        )
    }

    private static func executablePath(pid: pid_t) -> String? {
        let raw = processArguments(pid: pid)
        let bytes = Array(raw.utf8)
        let start = MemoryLayout<Int32>.size
        guard bytes.count > start else { return nil }

        let pathBytes = bytes[start...].prefix { $0 != 0 }
        guard !pathBytes.isEmpty else { return nil }
        return String(bytes: pathBytes, encoding: .utf8)
    }

    private static func processArguments(pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "" }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }

        // KERN_PROCARGS2 format: argc (int32), then exec path, then NUL-padded args.
        // Cap at ARG_MAX (the OS-wide argv+env ceiling) so the conversion never
        // runs away on a pathological process; sysctl can't return more than
        // that anyway, so in practice this just uses the full buffer.
        return String(decoding: buffer.prefix(min(size, Int(ARG_MAX))), as: UTF8.self)
    }

    /// Return the full argv of a running process, or [] if unavailable.
    ///
    /// Parses KERN_PROCARGS2 directly: `[argc:int32][exec_path\0...padding\0][argv[0]\0argv[1]\0...]`.
    /// Stops at argc strings so we don't bleed into the env block.
    public static func processArgv(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseArgv(rawProcargs2: buffer)
    }

    /// Return selected environment variables for a process.
    ///
    /// We never expose the full environment to callers — env can contain
    /// secrets, tokens, and PATHs that have no business in an overlay. The
    /// caller supplies the exact set of names it wants extracted.
    public static func processEnvironment(pid: pid_t, names: Set<String>) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [:] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }
        return parseEnvironment(rawProcargs2: buffer, names: names)
    }

    /// Pure parser exposed for tests.
    static func parseEnvironment(rawProcargs2 buffer: [UInt8], names: Set<String>) -> [String: String] {
        guard buffer.count >= 4 else { return [:] }
        let argc =
            Int(buffer[0])
            | Int(buffer[1]) << 8
            | Int(buffer[2]) << 16
            | Int(buffer[3]) << 24
        guard argc >= 0 else { return [:] }

        // Skip exec_path + padding (until first non-NUL after the path),
        // then skip argc null-terminated argv strings to land on the envp block.
        var i = 4
        while i < buffer.count && buffer[i] != 0 { i += 1 }
        while i < buffer.count && buffer[i] == 0 { i += 1 }

        var consumed = 0
        while consumed < argc && i < buffer.count {
            while i < buffer.count && buffer[i] != 0 { i += 1 }
            if i < buffer.count { i += 1 }  // skip terminator
            consumed += 1
        }

        // Now read env strings until empty entry or end of buffer.
        var env: [String: String] = [:]
        var start = i
        while i < buffer.count {
            if buffer[i] == 0 {
                if start == i { break }  // empty entry terminates envp
                let bytes = Array(buffer[start..<i])
                if let s = String(bytes: bytes, encoding: .utf8),
                   let eq = s.firstIndex(of: "=") {
                    let key = String(s[..<eq])
                    if names.contains(key) {
                        env[key] = String(s[s.index(after: eq)...])
                    }
                    if env.count == names.count { return env }
                }
                i += 1
                start = i
            } else {
                i += 1
            }
        }
        return env
    }

    /// Pure parser exposed for tests.
    static func parseArgv(rawProcargs2 buffer: [UInt8]) -> [String] {
        guard buffer.count >= 4 else { return [] }

        // argc is a little-endian uint32 on all Apple-supported architectures.
        let argc =
            Int(buffer[0])
            | Int(buffer[1]) << 8
            | Int(buffer[2]) << 16
            | Int(buffer[3]) << 24
        guard argc > 0 else { return [] }

        var i = 4
        // Skip exec_path: read until first NUL, then over any NUL padding.
        while i < buffer.count && buffer[i] != 0 { i += 1 }
        while i < buffer.count && buffer[i] == 0 { i += 1 }

        var argv: [String] = []
        argv.reserveCapacity(argc)
        var start = i
        while argv.count < argc && i < buffer.count {
            if buffer[i] == 0 {
                let bytes = Array(buffer[start..<i])
                argv.append(String(bytes: bytes, encoding: .utf8) ?? "")
                i += 1
                start = i
            } else {
                i += 1
            }
        }
        return argv
    }

    /// Check if a running process (by PID) is signed by 1Password's
    /// Apple Team ID. Used both to gate AX-observer attach to the
    /// 1Password app process and (via the static-code variant below)
    /// to classify `op` trigger binaries.
    public static func isRunningProcessSignedByOnePassword(pid: pid_t) -> Bool {
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code = code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            onePasswordRequirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement = requirement else {
            return false
        }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    /// Static-code check against 1Password's Team ID — used when
    /// classifying `op` trigger binaries for the matcher's
    /// `binaryVerified` predicate.
    private static func isSignedByOnePassword(path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath() as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode = staticCode else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            onePasswordRequirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement = requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }

    public static func allProcesses() -> [ProcessNode] {
        // Honor a short-lived cache so multiple chain builds in the same
        // dialog-handler invocation share one sysctl scan. Scanning every
        // process is the single largest cost in handleWindowEvent (~200ms on
        // a busy machine), and the per-handler call sequence does it 4×
        // (one in findTriggerProcesses + one per buildChain).
        cacheLock.lock()
        if let cached = cacheValue,
           DispatchTime.now().uptimeNanoseconds - cacheStamp.uptimeNanoseconds < cacheTTL {
            defer { cacheLock.unlock() }
            return cached
        }
        cacheLock.unlock()

        let fresh = scanAllProcesses()

        cacheLock.lock()
        cacheValue = fresh
        cacheStamp = DispatchTime.now()
        cacheLock.unlock()
        return fresh
    }

    private static var cacheValue: [ProcessNode]?
    private static var cacheStamp: DispatchTime = .now()
    private static let cacheLock = NSLock()
    /// 250 ms is enough to dedupe within one handleWindowEvent burst
    /// (find + 3×buildChain runs in ~30 ms after deduplication) without
    /// risking stale data across dialog events seconds apart.
    private static let cacheTTL: UInt64 = 250 * 1_000_000

    private static func scanAllProcesses() -> [ProcessNode] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
            return []
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else {
            return []
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actualCount).map(nodeFromKinfo)
    }

    private static func nodeFromKinfo(_ info: kinfo_proc) -> ProcessNode {
        let pid = info.kp_proc.p_pid
        let ppid = info.kp_eproc.e_ppid

        let name: String = withUnsafePointer(to: info.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN + 1)) {
                String(cString: $0)
            }
        }

        let tdev = info.kp_eproc.e_tdev
        var tty: String? = nil
        if tdev != 0, tdev != ~0 {
            if let cName = devname(tdev, S_IFCHR) {
                tty = "/dev/" + String(cString: cName)
            }
        }

        return ProcessNode(
            pid: pid,
            ppid: ppid,
            name: name,
            tty: tty,
            executablePath: nil,
            isVerifiedOnePasswordCLI: false
        )
    }
}
