import Foundation
import Testing
@testable import OrreryCore

@Suite("ShellFunctionGenerator use)")
struct ShellFunctionUseV31Tests {

    @Test("orrery() function has a use) case")
    func hasUseCase() {
        let sh = ShellFunctionGenerator.generate()
        #expect(sh.contains("use)"),
            "orrery() should have a `use)` case in its switch")
    }

    @Test("use) calls _account-dir to check for v3.1 layout")
    func callsAccountDir() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(800))
        #expect(body.contains("_account-dir"),
            "use) should call _account-dir to detect v3.1 layout")
    }

    @Test("use) exports CLAUDE_CONFIG_DIR on v3.1 path")
    func exportsConfigDir() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(800))
        #expect(body.contains("export CLAUDE_CONFIG_DIR"),
            "use) should export CLAUDE_CONFIG_DIR when v3.1 lookup succeeds")
    }

    @Test("use) falls back to orrery-bin use on lookup failure")
    func fallsBackToBinary() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(800))
        // The fallback should re-invoke `command orrery-bin use ...` so the
        // v3.0.4 materialize path still runs for non-migrated accounts.
        #expect(body.contains("command orrery-bin use"),
            "use) should fall back to `command orrery-bin use` when v3.1 lookup fails")
    }
}
