# op-who

A macOS menu bar utility that shows which process triggered a [1Password](https://1password.com) approval dialog — whether from the CLI (`op`) or the SSH agent.

When 1Password shows its approval dialog, op-who pops up a floating overlay showing:

- The full process chain from the trigger up to the terminal (e.g. `op → bash → node → zsh`)
- Working directory of the requesting process
- Claude Code session name, if applicable
- Terminal tab title matched by TTY
- PID and TTY device
- Buttons to jump to the terminal tab or send a notification to the TTY

## Why?

1Password's approval dialog tells you *which app* is requesting access, but not *which terminal session* or *which command* started it. If you have multiple terminals open running builds, git operations, or Claude Code sessions, you're left guessing. op-who fills in the missing context so you can approve (or deny) with confidence.

## Install

```bash
brew tap sunstoneinstitute/tap
brew install --cask sunstoneinstitute/tap/op-who
```

Or build from source:

```bash
swift build
scripts/bundle.sh
open .build/op-who.app
```

## Requirements

- macOS 13+
- 1Password 8 with CLI or SSH agent integration enabled

## How it works

1. Watches for the 1Password process and verifies its code signature (Apple Team ID `2BUA8C4S2C`)
2. Attaches an AX observer to detect new windows (approval dialogs)
3. Validates that detected windows are actual approval dialogs (not just any 1Password window)
4. Finds trigger processes: `op` CLI processes (signature-verified) or SSH client processes (`ssh`, `git`, `scp`, `sftp`, `rsync`)
5. Walks each trigger's parent chain, stopping at macOS app boundaries (since 1Password already shows the app name)
6. Looks up terminal tab titles via AppleScript (Terminal.app, iTerm2) or the Accessibility API (Ghostty, Warp, and others)
7. If Claude Code is detected in the chain, extracts the session/project name
8. Shows a floating overlay positioned near the 1Password dialog
9. Automatically dismisses the overlay when the dialog closes or trigger processes exit

## Supported terminals

| Terminal | Tab title lookup | Tab activation |
|----------|-----------------|----------------|
| Terminal.app | AppleScript | AppleScript |
| iTerm2 | AppleScript | AppleScript |
| Ghostty, Warp, others | Accessibility API | App activation |

## Security

op-who validates the identity of processes it interacts with:

- **1Password app** — code signature verified before attaching the AX observer
- **`op` CLI** — executable path resolved and code signature checked; verified binaries shown in green, unverified in orange
- **TTY paths** — validated against `/dev/ttys[0-9]+` before any read/write operations
- **TTY messages** — require user confirmation before writing to the terminal

## Permissions

- **Accessibility** — required to detect 1Password dialogs and read window attributes
- **Automation** — prompted on first use of "Show Tab" (sends AppleScript to terminal apps)

## Testing

```bash
swift test
```

## Releasing

Signed, notarized release builds are created automatically when a version tag is pushed. The GitHub Actions workflow builds the `.app` bundle, signs and notarizes it, creates a GitHub Release, and updates the Homebrew cask.

See [docs/cert-sign-guide.md](docs/cert-sign-guide.md) for certificate setup.

## License

MIT
