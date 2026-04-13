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

    private static let onePasswordTeamID = "2BUA8C4S2C"

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "io.cmux",
        "com.cmux.cmux",
    ]

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

    /// Find all trigger processes (op + SSH clients) in a single process scan.
    /// Does NOT perform signature verification — that is deferred to chain
    /// building so it doesn't block initial detection.
    public static func findTriggerProcesses() -> [ProcessNode] {
        let triggerNames: Set<String> = ["op", "ssh", "git", "scp", "sftp", "rsync"]
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

    /// Try to detect a Claude Code session name from a claude/node process.
    /// Looks at open file descriptors for paths containing .claude/projects/.
    public static func claudeSessionInfo(pid: pid_t) -> String? {
        // Use lsof to find open files — more reliable than raw proc APIs from Swift
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", "\(pid)", "-Fn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Look for paths like ~/.claude/projects/<project>/<session-file>
        // or the CWD (current working directory line starts with "n" after a "cwd" fd)
        var cwd: String? = nil
        for line in output.split(separator: "\n") {
            let str = String(line)
            if str.hasPrefix("n") {
                let path = String(str.dropFirst())
                if path.contains(".claude/projects/") {
                    // Try to extract project path from the claude directory structure
                    // Format: ~/.claude/projects/-Users-foo-project/
                    if let range = path.range(of: ".claude/projects/") {
                        let afterProjects = String(path[range.upperBound...])
                        let projectDir = afterProjects.split(separator: "/").first.map(String.init) ?? ""
                        // Decode: -Users-foo-project → /Users/foo/project
                        let decoded = projectDir.replacingOccurrences(of: "-", with: "/")
                        // Return just the last path component as a readable name
                        let projectName = decoded.split(separator: "/").last.map(String.init)
                        if let name = projectName, !name.isEmpty {
                            return name
                        }
                    }
                }
                // Track CWD as fallback
                if cwd == nil, path.hasPrefix("/"), !path.contains(".claude") {
                    cwd = path
                }
            }
        }

        // Fallback: use CWD basename
        if let cwd = cwd {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return nil
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

        // KERN_PROCARGS2 format: argc (int32), then exec path, then NUL-padded args
        return String(decoding: buffer.prefix(min(size, 4096)), as: UTF8.self)
    }

    /// Check if a running process (by PID) is signed by 1Password's Team ID.
    public static func isRunningProcessSignedByOnePassword(pid: pid_t) -> Bool {
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code = code else {
            return false
        }

        let requirementText = """
            anchor apple generic and certificate leaf[subject.OU] = "\(onePasswordTeamID)"
            """ as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement = requirement else {
            return false
        }

        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    private static func isSignedByOnePassword(path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath() as CFURL
        var staticCode: SecStaticCode?

        guard SecStaticCodeCreateWithPath(url, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode = staticCode else {
            return false
        }

        let requirementText = """
            anchor apple generic and certificate leaf[subject.OU] = "\(onePasswordTeamID)"
            """ as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement = requirement else {
            return false
        }

        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }

    public static func allProcesses() -> [ProcessNode] {
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
