import AppKit
import ApplicationServices

public enum TerminalHelper {

    // MARK: - Tab Title Lookup

    /// Get the tab/session title for a TTY in a specific terminal app.
    public static func tabTitle(forTTY tty: String, terminalBundleID: String?, terminalPID: pid_t?) -> String? {
        guard isValidTTYPath(tty) else {
            NSLog("[op-who] Invalid TTY path: \(tty)")
            return nil
        }
        guard let bid = terminalBundleID else {
            // No known terminal — try AX fallback on the frontmost terminal-like app
            return nil
        }

        switch bid {
        case "com.apple.Terminal":
            return appleScriptTabTitle(tty: tty, script: """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                return name of t
                            end if
                        end repeat
                    end repeat
                end tell
                """)

        case "com.googlecode.iterm2":
            return appleScriptTabTitle(tty: tty, script: """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    return name of s
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)

        default:
            // For ghostty, Warp, cmux, etc. — use Accessibility API to find
            // the window whose title contains the TTY or just get all window titles
            if let pid = terminalPID {
                return axWindowTitle(forPID: pid, tty: tty)
            }
            return nil
        }
    }

    // MARK: - Tab Activation

    /// Try to activate the terminal tab that owns a given TTY.
    public static func activateTab(forTTY tty: String, terminalBundleID: String? = nil) {
        guard isValidTTYPath(tty) else {
            NSLog("[op-who] Invalid TTY path: \(tty)")
            return
        }
        let bid = terminalBundleID ?? detectTerminalBundleID()
        guard let bid = bid else {
            NSLog("[op-who] No supported terminal found for TTY \(tty)")
            return
        }

        var ok = false

        switch bid {
        case "com.googlecode.iterm2":
            ok = runAppleScript("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select s
                                    set index of w to 1
                                    return "found"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)

        case "com.apple.Terminal":
            ok = runAppleScript("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end tell
                """)

        default:
            break
        }

        // Fall back to activating the app if AppleScript failed or wasn't attempted
        if !ok {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate()
            }
        }
    }

    /// Write a message to a TTY device.
    public static func writeMessage(to tty: String, message: String) {
        guard isValidTTYPath(tty) else {
            NSLog("[op-who] Invalid TTY path: \(tty)")
            return
        }
        guard let fh = FileHandle(forWritingAtPath: tty) else {
            NSLog("[op-who] Cannot open \(tty) for writing")
            return
        }
        defer { fh.closeFile() }

        if let data = message.data(using: .utf8) {
            fh.write(data)
        }
    }

    // MARK: - Private

    /// Validate that a TTY path matches the expected macOS format `/dev/ttys[0-9]+`.
    public static func isValidTTYPath(_ tty: String) -> Bool {
        let pattern = #"^/dev/ttys\d+$"#
        return tty.range(of: pattern, options: .regularExpression) != nil
    }

    private static func detectTerminalBundleID() -> String? {
        let knownTerminals = [
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "dev.warp.Warp",
        ]
        for bid in knownTerminals {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                return bid
            }
        }
        return nil
    }

    private static func appleScriptTabTitle(tty: String, script: String) -> String? {
        guard let s = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = s.executeAndReturnError(&error)
        if let error = error {
            NSLog("[op-who] AppleScript error getting tab title: \(error)")
            return nil
        }
        let title = result.stringValue
        return (title?.isEmpty ?? true) ? nil : title
    }

    /// Use the Accessibility API to get window titles for a terminal process.
    /// Falls back to finding a window whose title mentions the TTY path, or
    /// just returns the first window title.
    private static func axWindowTitle(forPID pid: pid_t, tty: String) -> String? {
        let appEl = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        // Try to find a window whose title contains the tty device name
        let ttyShort = tty.replacingOccurrences(of: "/dev/", with: "")
        var firstTitle: String? = nil

        for win in windows {
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String, !title.isEmpty {
                if firstTitle == nil { firstTitle = title }
                if title.contains(ttyShort) || title.contains(tty) {
                    return title
                }
            }
        }

        return firstTitle
    }

    /// Run an AppleScript and return whether it succeeded.
    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            NSLog("[op-who] AppleScript error: \(error)")
            return false
        }
        return true
    }
}
