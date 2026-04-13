# Contributing to op-who

## Architecture

Swift Package Manager project with a library target (`OpWhoLib`) and thin executable (`op-who`). Non-sandboxed (needs Accessibility API access). Distributed as a signed/notarized `.app` bundle.

### Source layout

```
Sources/
  OpWhoLib/           — library target (all logic)
    ProcessTree.swift
    OnePasswordWatcher.swift
    OverlayPanel.swift
    TerminalHelper.swift
    Info.plist        — .app bundle metadata (excluded from SPM compilation)
  op-who/
    main.swift        — NSApplication setup, status bar item, accessibility check
Tests/
  ProcessTreeTests.swift
  TerminalHelperTests.swift
```

### Source files

- `main.swift` — NSApplication setup, status bar item ("op?"), accessibility permission check
- `ProcessTree.swift` — Process discovery via `sysctl(KERN_PROC)`, parent chain walking, Mac app detection via NSWorkspace, Claude Code detection via `KERN_PROCARGS2` and `lsof`, CWD lookup via `proc_pidinfo`
- `OnePasswordWatcher.swift` — AXObserver watching 1Password for window creation/focus events, triggers on both `op` (CLI) and SSH client processes (ssh, git, scp, sftp, rsync), polls to detect dialog dismissal
- `OverlayPanel.swift` — Floating NSPanel showing process chain, CWD, session info, TTY, and action buttons
- `TerminalHelper.swift` — Tab title lookup (AppleScript for Terminal.app/iTerm2, AX API fallback), tab activation, TTY message writing

## Build & run

```bash
swift build
scripts/bundle.sh              # assemble .app bundle (debug)
open .build/op-who.app
```

## Testing

```bash
swift test
```

Tests use Swift Testing (`import Testing`). Covers pure logic: ProcessNode display names, chain formatting, path tidying, TTY validation, process enumeration.

## Releasing

### Version bump, changelog, and tag

Use the `/release` slash command (if using Claude Code), or manually:

```bash
echo "changelog text" | scripts/release-version.sh --bump minor
```

This reads a changelog entry from stdin, bumps the version in `Sources/OpWhoLib/Info.plist`, prepends the entry to `CHANGELOG.md`, commits, and creates a git tag.

The `--bump` flag accepts `major`, `minor`, or `patch`. Use `--dry-run` to preview without making changes.

### Signed release builds

Signed, notarized release builds are created automatically when a version tag is pushed. The GitHub Actions workflow builds the `.app` bundle, signs and notarizes it, creates a GitHub Release, and updates the Homebrew cask.

To build a signed release locally:

```bash
scripts/release.sh                        # auto-detect signing identity
scripts/release.sh "Developer ID Application: Your Name (TEAMID)"
```

Prerequisites:
- A "Developer ID Application" certificate in your keychain
- Notarization credentials stored via `xcrun notarytool store-credentials "op-who"`

The script builds, assembles the `.app` bundle, signs with hardened runtime, notarizes, staples, and produces `.build/op-who.zip`.

### Certificate and signing setup

See [docs/cert-sign-guide.md](docs/cert-sign-guide.md) for full instructions on obtaining a Developer ID certificate, exporting it for CI, and configuring GitHub Actions secrets.

## Install (end users)

```bash
brew tap sunstoneinstitute/tap
brew install --cask sunstoneinstitute/tap/op-who
```
