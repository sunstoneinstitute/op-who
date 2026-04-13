import Testing
@testable import OpWhoLib
import Foundation

@Suite("ProcessNode")
struct ProcessNodeTests {

    @Test func displayName() {
        let node = ProcessNode(pid: 123, ppid: 1, name: "bash", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false)
        #expect(node.displayName == "bash (123)")
    }

    @Test func chainDisplayNameNormal() {
        let node = ProcessNode(pid: 1, ppid: 0, name: "ssh", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false)
        #expect(node.chainDisplayName == "ssh")
    }

    @Test func chainDisplayNameVerifiedOp() {
        let node = ProcessNode(pid: 1, ppid: 0, name: "op", tty: nil, executablePath: "/usr/local/bin/op", isVerifiedOnePasswordCLI: true)
        #expect(node.chainDisplayName == "op")
    }

    @Test func chainDisplayNameUnverifiedOp() {
        let node = ProcessNode(pid: 1, ppid: 0, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false)
        #expect(node.chainDisplayName == "unverified op")
    }
}

@Suite("ProcessTree")
struct ProcessTreeTests {

    @Test func formatChainSingle() {
        let chain = [
            ProcessNode(pid: 1, ppid: 0, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: true),
        ]
        #expect(ProcessTree.formatChain(chain) == "op")
    }

    @Test func formatChainMultiple() {
        let chain = [
            ProcessNode(pid: 10, ppid: 20, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: true),
            ProcessNode(pid: 20, ppid: 30, name: "bash", tty: "/dev/ttys001", executablePath: nil, isVerifiedOnePasswordCLI: false),
            ProcessNode(pid: 30, ppid: 40, name: "node", tty: "/dev/ttys001", executablePath: nil, isVerifiedOnePasswordCLI: false),
        ]
        #expect(ProcessTree.formatChain(chain) == "op \u{2192} bash \u{2192} node")
    }

    @Test func formatChainUnverifiedOp() {
        let chain = [
            ProcessNode(pid: 10, ppid: 20, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
            ProcessNode(pid: 20, ppid: 30, name: "bash", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
        ]
        #expect(ProcessTree.formatChain(chain) == "unverified op \u{2192} bash")
    }

    @Test func tidyPathHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ProcessTree.tidyPath(home) == "~")
    }

    @Test func tidyPathSubdir() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ProcessTree.tidyPath(home + "/Projects/op-who") == "~/Projects/op-who")
    }

    @Test func tidyPathNonHome() {
        #expect(ProcessTree.tidyPath("/usr/local/bin") == "/usr/local/bin")
    }

    @Test func tidyPathRoot() {
        #expect(ProcessTree.tidyPath("/") == "/")
    }

    @Test func allProcessesReturnsResults() {
        let procs = ProcessTree.allProcesses()
        #expect(!procs.isEmpty)
    }

    @Test func allProcessesContainsCurrentProcess() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let procs = ProcessTree.allProcesses()
        #expect(procs.contains { $0.pid == myPID })
    }

    @Test func processCWDForSelf() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let cwd = ProcessTree.processCWD(pid: myPID)
        #expect(cwd != nil)
        #expect(cwd != "")
    }

    @Test func processCWDForInvalidPID() {
        let cwd = ProcessTree.processCWD(pid: -1)
        #expect(cwd == nil)
    }
}
