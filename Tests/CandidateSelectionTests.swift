import Testing
import Darwin
import Foundation
@testable import OpWhoLib

private func n(_ name: String, pid: pid_t, ppid: pid_t = 1, verified: Bool = false) -> ProcessNode {
    ProcessNode(
        pid: pid, ppid: ppid, name: name, tty: nil,
        executablePath: nil, isVerifiedOnePasswordCLI: verified
    )
}

private func entry(pid: pid_t, chain: [ProcessNode]) -> OverlayPanel.ProcessEntry {
    OverlayPanel.ProcessEntry(
        pid: pid, chain: chain, triggerArgv: [],
        tty: nil, tabTitle: nil, tabShortcut: nil,
        claudeSession: nil, claudeContext: nil,
        terminalBundleID: nil, terminalPID: nil, cwd: nil,
        triggerCwd: nil,
        cmuxWorkspaceID: nil, cmuxTabID: nil, cmuxSurface: nil,
        startTime: nil, pluginUpdate: nil,
        summary: RequestSummary(kind: .unknown, title: "", subtitle: nil, isWarning: false),
        matchedRuleID: nil, matchedRuleName: nil, matchedBuiltInID: nil
    )
}

private func candidate(
    kind: RequestKind, pid: pid_t = 100, startTime: Date? = nil
) -> TriggerCandidate {
    TriggerCandidate(
        entry: entry(pid: pid, chain: [n("dummy", pid: pid)]),
        kind: kind,
        startTime: startTime
    )
}

@Suite("foldOpHelper")
struct FoldOpHelperTests {

    @Test func foldsUnverifiedChildIntoVerifiedParent() {
        let chain = [
            n("op", pid: 100, ppid: 200, verified: false),
            n("op", pid: 200, ppid: 300, verified: true),
            n("zsh", pid: 300),
        ]
        let folded = foldOpHelper(chain: chain)
        #expect(folded.count == 2)
        #expect(folded[0].pid == 200)
        #expect(folded[0].isVerifiedOnePasswordCLI)
        #expect(folded[1].name == "zsh")
    }

    @Test func walksMultipleHelperLevels() {
        let chain = [
            n("op", pid: 100, verified: false),
            n("op", pid: 200, verified: false),
            n("op", pid: 300, verified: true),
            n("zsh", pid: 400),
        ]
        let folded = foldOpHelper(chain: chain)
        #expect(folded.first?.pid == 300)
        #expect(folded.count == 2)
    }

    @Test func doesNotFoldWhenParentIsNotOp() {
        let chain = [
            n("op", pid: 100, verified: false),
            n("zsh", pid: 200),
        ]
        let folded = foldOpHelper(chain: chain)
        #expect(folded.count == 2)
        #expect(folded[0].pid == 100)
    }

    @Test func doesNotFoldVerifiedOp() {
        let chain = [
            n("op", pid: 100, verified: true),
            n("op", pid: 200, verified: true),
            n("zsh", pid: 300),
        ]
        let folded = foldOpHelper(chain: chain)
        #expect(folded.count == 3)
        #expect(folded[0].pid == 100)
    }

    @Test func emptyChainReturnsEmpty() {
        #expect(foldOpHelper(chain: []).isEmpty)
    }

    @Test func singleNodeUnchanged() {
        let chain = [n("op", pid: 100, verified: false)]
        let folded = foldOpHelper(chain: chain)
        #expect(folded.count == 1)
    }
}

@Suite("selectBestCandidate")
struct SelectBestCandidateTests {

    @Test func nilOnEmpty() {
        #expect(selectBestCandidate([]) == nil)
    }

    @Test func opBeatsSsh() {
        let op = candidate(kind: .onePasswordCLI, pid: 1)
        let ssh = candidate(kind: .ssh, pid: 2)
        #expect(selectBestCandidate([ssh, op])?.entry.pid == 1)
    }

    @Test func sshBeatsUnknownAndUnverified() {
        let ssh = candidate(kind: .ssh, pid: 1)
        let unk = candidate(kind: .unknown, pid: 2)
        let bad = candidate(kind: .unverifiedOp, pid: 3)
        #expect(selectBestCandidate([bad, unk, ssh])?.entry.pid == 1)
    }

    @Test func unverifiedIsLastResort() {
        let bad = candidate(kind: .unverifiedOp, pid: 7)
        #expect(selectBestCandidate([bad])?.entry.pid == 7)
    }

    @Test func sameKindOldestWins() {
        let now = Date()
        let older = candidate(kind: .ssh, pid: 1, startTime: now.addingTimeInterval(-60))
        let newer = candidate(kind: .ssh, pid: 2, startTime: now)
        #expect(selectBestCandidate([newer, older])?.entry.pid == 1)
    }

    @Test func sameKindMissingStartTimeRanksLast() {
        let now = Date()
        let withTime = candidate(kind: .ssh, pid: 1, startTime: now)
        let withoutTime = candidate(kind: .ssh, pid: 2, startTime: nil)
        #expect(selectBestCandidate([withoutTime, withTime])?.entry.pid == 1)
    }

    @Test func opVerifiedBeatsOldUnverified() {
        // Even if the unverified helper started earlier, the verified op wins.
        let old = Date().addingTimeInterval(-3600)
        let unverified = candidate(kind: .unverifiedOp, pid: 1, startTime: old)
        let verified = candidate(kind: .onePasswordCLI, pid: 2, startTime: Date())
        #expect(selectBestCandidate([unverified, verified])?.entry.pid == 2)
    }
}
