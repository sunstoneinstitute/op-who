import Foundation
import Testing
@testable import OpWhoLib

@Suite("OverlayPanel.terminalRowText")
struct OverlayPanelTerminalRowTextTests {

    private func entry(
        cmuxSurface: CmuxSurfaceInfo? = nil,
        tabTitle: String? = nil,
        tabShortcut: String? = nil,
        terminalBundleID: String? = nil
    ) -> OverlayPanel.ProcessEntry {
        OverlayPanel.ProcessEntry(
            pid: 1,
            chain: [],
            triggerArgv: [],
            tty: "/dev/ttys999",
            tabTitle: tabTitle,
            tabShortcut: tabShortcut,
            claudeSession: nil,
            claudeContext: nil,
            terminalBundleID: terminalBundleID,
            terminalPID: nil,
            cwd: nil,
            triggerCwd: nil,
            cmuxWorkspaceID: nil,
            cmuxTabID: nil,
            cmuxSurface: cmuxSurface,
            startTime: nil,
            pluginUpdate: nil,
            summary: RequestSummary(kind: .unknown, title: "", subtitle: nil, isWarning: false),
            matchedRuleID: nil,
            matchedRuleName: nil,
            matchedBuiltInID: nil
        )
    }

    // MARK: - cmuxSurface present

    @Test func cmuxSurfaceWithNamedWorkspaceAndTab() {
        // We intentionally drop the tab title for cmux — workspace name plus
        // the ⌘N/⌃N shortcuts give the user enough to navigate.
        let s = CmuxSurfaceInfo(
            workspaceRef: "workspace:11",
            workspaceTitle: "trusthere",
            surfaceRef: "surface:25",
            surfaceTitle: "main",
            tty: "ttys021"
        )
        let text = OverlayPanel.terminalRowText(
            entry: entry(cmuxSurface: s, terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "trusthere · cmux")
    }

    @Test func cmuxSurfaceWithGenericWorkspaceTitleAndNoDescriptionOmitsWorkspace() {
        // Even when cmux returns "Item-0" (cmux's auto-placeholder), we
        // shouldn't surface it. With no description and no useful surface
        // title, fall back to just the terminal name.
        let s = CmuxSurfaceInfo(
            workspaceRef: "workspace:99",
            workspaceTitle: "Item-0",
            workspaceDescription: nil,
            surfaceRef: "surface:99",
            surfaceTitle: "",
            tty: "ttys077"
        )
        let text = OverlayPanel.terminalRowText(
            entry: entry(cmuxSurface: s, terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "cmux")
    }

    @Test func cmuxSurfaceWithGenericWorkspaceFallsBackToDescription() {
        let s = CmuxSurfaceInfo(
            workspaceRef: "workspace:99",
            workspaceTitle: "Item-0",
            workspaceDescription: "scratch experiments",
            surfaceRef: "surface:99",
            surfaceTitle: "main",
            tty: "ttys077"
        )
        let text = OverlayPanel.terminalRowText(
            entry: entry(cmuxSurface: s, terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "scratch experiments · cmux")
    }

    @Test func cmuxSurfaceWithGenericSurfaceTitleOmitsTabClause() {
        // Surface title "Item-1" is also a cmux placeholder — drop it.
        let s = CmuxSurfaceInfo(
            workspaceRef: "workspace:11",
            workspaceTitle: "trusthere",
            surfaceRef: "surface:99",
            surfaceTitle: "Item-1",
            tty: "ttys021"
        )
        let text = OverlayPanel.terminalRowText(
            entry: entry(cmuxSurface: s, terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "trusthere · cmux")
    }

    // MARK: - cmuxSurface absent (fallback path)

    @Test func cmuxWithoutSurfaceIgnoresAXWindowTitle() {
        // This is the user-reported bug: when cmuxSurface lookup fails, the
        // AX window title for cmux is a placeholder like "Item-0" — we must
        // NOT show it as if it were the workspace name.
        let text = OverlayPanel.terminalRowText(
            entry: entry(tabTitle: "Item-0", terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "cmux")
    }

    @Test func cmuxWithoutSurfaceIgnoresEvenRealLookingTabTitle() {
        // Even if the AX title looks plausible, it isn't trustworthy for cmux
        // (e.g. it can be the title of an unrelated tab strip window). We
        // err on the side of "no info" rather than "wrong info".
        let text = OverlayPanel.terminalRowText(
            entry: entry(tabTitle: "trusthere", terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "cmux")
    }

    @Test func nonCmuxTerminalKeepsTabTitleFallback() {
        // For iTerm/Terminal.app/ghostty etc. the AX-derived tab title is the
        // user-visible tab name and is worth showing.
        let text = OverlayPanel.terminalRowText(
            entry: entry(tabTitle: "1. zsh — work", terminalBundleID: "com.googlecode.iterm2"),
            termName: "iTerm"
        )
        #expect(text == "1. zsh — work · iTerm")
    }

    @Test func noSurfaceAndNoTabTitleReturnsTermNameOnly() {
        let text = OverlayPanel.terminalRowText(
            entry: entry(terminalBundleID: "com.apple.Terminal"),
            termName: "Terminal"
        )
        #expect(text == "Terminal")
    }

    // MARK: - title + shortcut composition

    @Test func tabTitleOnlyKeepsExistingFormat() {
        let text = OverlayPanel.terminalRowText(
            entry: entry(tabTitle: "mattermost", terminalBundleID: "com.googlecode.iterm2"),
            termName: "iTerm"
        )
        #expect(text == "mattermost · iTerm")
    }

    @Test func tabTitlePlusShortcutShowsBoth() {
        // User renamed the tab AND we have a shortcut hint — show both,
        // shortcut trailing.
        let text = OverlayPanel.terminalRowText(
            entry: entry(tabTitle: "mattermost", tabShortcut: "⌘3", terminalBundleID: "com.googlecode.iterm2"),
            termName: "iTerm"
        )
        #expect(text == "mattermost · iTerm ⌘3")
    }

    @Test func tabTitlePlusMultiWindowShortcut() {
        let text = OverlayPanel.terminalRowText(
            entry: entry(tabTitle: "mattermost", tabShortcut: "window 2 ⌘1", terminalBundleID: "com.googlecode.iterm2"),
            termName: "iTerm"
        )
        #expect(text == "mattermost · iTerm window 2 ⌘1")
    }

    @Test func shortcutOnlyRendersWithoutTabWrapping() {
        #expect(
            OverlayPanel.terminalRowText(
                entry: entry(tabShortcut: "⌘1", terminalBundleID: "com.googlecode.iterm2"),
                termName: "iTerm"
            ) == "iTerm ⌘1"
        )
        #expect(
            OverlayPanel.terminalRowText(
                entry: entry(tabShortcut: "⌘9", terminalBundleID: "com.googlecode.iterm2"),
                termName: "iTerm"
            ) == "iTerm ⌘9"
        )
        #expect(
            OverlayPanel.terminalRowText(
                entry: entry(tabShortcut: "window 2 ⌘1", terminalBundleID: "com.googlecode.iterm2"),
                termName: "iTerm"
            ) == "iTerm window 2 ⌘1"
        )
    }

    @Test func neitherTitleNorShortcutReturnsBareTermName() {
        let text = OverlayPanel.terminalRowText(
            entry: entry(terminalBundleID: "com.googlecode.iterm2"),
            termName: "iTerm"
        )
        #expect(text == "iTerm")
    }

    // MARK: - cmux keyboard-shortcut hints

    @Test func cmuxSurfaceWithIndicesRendersShortcuts() {
        let s = CmuxSurfaceInfo(
            workspaceRef: "workspace:0:1",
            workspaceTitle: "trusthere",
            surfaceRef: "surface:25",
            surfaceTitle: "main",
            tty: "ttys021",
            workspaceIndex: 2,
            tabIndex: 1
        )
        let text = OverlayPanel.terminalRowText(
            entry: entry(cmuxSurface: s, terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "trusthere · cmux ⌘2 ⌃1")
    }

    @Test func cmuxSingleTabWorkspaceHidesTabShortcut() {
        // When the workspace has exactly one tab, ⌃1 is trivial — hide it.
        // ⌘N (workspace shortcut) is still useful and stays.
        let s = CmuxSurfaceInfo(
            workspaceRef: "workspace:0:1",
            workspaceTitle: "trusthere",
            surfaceRef: "surface:25",
            surfaceTitle: "main",
            tty: "ttys021",
            workspaceIndex: 2,
            tabIndex: 1,
            workspaceTabCount: 1
        )
        let text = OverlayPanel.terminalRowText(
            entry: entry(cmuxSurface: s, terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "trusthere · cmux ⌘2")
    }

    @Test func cmuxMultipleTabsKeepTabShortcut() {
        let s = CmuxSurfaceInfo(
            workspaceRef: "workspace:0:1",
            workspaceTitle: "trusthere",
            surfaceRef: "surface:25",
            surfaceTitle: "main",
            tty: "ttys021",
            workspaceIndex: 2,
            tabIndex: 1,
            workspaceTabCount: 3
        )
        let text = OverlayPanel.terminalRowText(
            entry: entry(cmuxSurface: s, terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "trusthere · cmux ⌘2 ⌃1")
    }

    @Test func cmuxSurfaceShortcutOnlyWhenIndexPresent() {
        // 0 means "unknown index" — render no shortcut for that side.
        let s = CmuxSurfaceInfo(
            workspaceRef: "workspace:0:1",
            workspaceTitle: "trusthere",
            surfaceRef: "surface:25",
            surfaceTitle: "main",
            tty: "ttys021",
            workspaceIndex: 0,
            tabIndex: 3
        )
        let text = OverlayPanel.terminalRowText(
            entry: entry(cmuxSurface: s, terminalBundleID: "com.cmuxterm.app"),
            termName: "cmux"
        )
        #expect(text == "trusthere · cmux ⌃3")
    }
}
