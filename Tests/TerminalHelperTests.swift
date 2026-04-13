import Testing
@testable import OpWhoLib

@Suite("TerminalHelper.isValidTTYPath")
struct TTYPathValidationTests {

    @Test func validPaths() {
        #expect(TerminalHelper.isValidTTYPath("/dev/ttys000"))
        #expect(TerminalHelper.isValidTTYPath("/dev/ttys001"))
        #expect(TerminalHelper.isValidTTYPath("/dev/ttys123"))
        #expect(TerminalHelper.isValidTTYPath("/dev/ttys9999"))
    }

    @Test func emptyString() {
        #expect(!TerminalHelper.isValidTTYPath(""))
    }

    @Test func wrongDeviceType() {
        #expect(!TerminalHelper.isValidTTYPath("/dev/tty"))
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttyp0"))
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttys"))
    }

    @Test func pathTraversal() {
        #expect(!TerminalHelper.isValidTTYPath("../../../etc/passwd"))
        #expect(!TerminalHelper.isValidTTYPath("/tmp/evil"))
    }

    @Test func injectionAttempts() {
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttys001; rm -rf /"))
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttys001\n/etc/passwd"))
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttys001 "))
    }
}
