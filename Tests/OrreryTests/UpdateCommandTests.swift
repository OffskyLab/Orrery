import Testing
@testable import OrreryCore

@Suite("UpdateCommand.shellBody")
struct UpdateCommandTests {

    @Test("--pre passes --pre-release to the install script and bypasses brew (macOS)")
    func preBypassesBrew() {
        let body = UpdateCommand.shellBody(isMacOS: true, pre: true)
        #expect(body.contains("| bash -s -- --pre-release"))
        #expect(!body.contains("brew upgrade"))
    }

    @Test("default (no --pre) prefers brew on macOS and does not request pre-releases")
    func defaultPrefersBrew() {
        let body = UpdateCommand.shellBody(isMacOS: true, pre: false)
        #expect(body.contains("brew upgrade orrery"))
        #expect(!body.contains("--pre-release"))
    }

    @Test("linux always uses the install script; --pre adds --pre-release")
    func linuxUsesScript() {
        let stable = UpdateCommand.shellBody(isMacOS: false, pre: false)
        #expect(!stable.contains("brew"))
        #expect(!stable.contains("--pre-release"))
        let pre = UpdateCommand.shellBody(isMacOS: false, pre: true)
        #expect(pre.contains("--pre-release"))
    }

    @Test("bookkeeping (clear notice + stamp ts) is appended for every combination")
    func bookkeepingAlwaysAppended() {
        for isMacOS in [true, false] {
            for pre in [true, false] {
                let body = UpdateCommand.shellBody(isMacOS: isMacOS, pre: pre)
                #expect(body.contains(".update-notice"))
                #expect(body.contains(".update-ts"))
            }
        }
    }
}
