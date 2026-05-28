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
        let body = String(sh[useStart.upperBound...].prefix(1500))
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
        let body = String(sh[useStart.upperBound...].prefix(1500))
        #expect(body.contains("export CLAUDE_CONFIG_DIR"),
            "use) should export CLAUDE_CONFIG_DIR when v3.1 lookup succeeds")
    }

    @Test("use) routes --codex / --gemini directly to orrery-bin use")
    func codexGeminiRouteDirect() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(1500))
        // Should explicitly check for --codex / --gemini
        #expect(body.contains("--codex") || body.contains("--gemini"),
            "use) should route codex/gemini explicitly")
        #expect(body.contains("command orrery-bin use"),
            "use) should route codex/gemini to command orrery-bin use")
    }

    @Test("use) does NOT silently swallow _account-dir errors for claude")
    func surfacesAccountDirErrors() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(1500))
        // The error path should NOT have the silent `2>/dev/null || true` pattern
        // around _account-dir; instead it should surface errors.
        #expect(!body.contains("2>/dev/null"),
            "use) must not silence _account-dir errors with 2>/dev/null")
        // Should surface errors to stderr or pass them through naturally
        #expect(body.contains(">&2") || body.contains("return 1"),
            "use) should surface _account-dir errors and return non-zero")
    }

    @Test("use) bypasses v3.1 fast-path for --help / --version")
    func bypassesHelpVersion() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(1500))
        // Body should explicitly check for --help / --version BEFORE the
        // _account-dir / CLAUDE_CONFIG_DIR export logic.
        let helpIdx = body.range(of: "--help")?.lowerBound
        let accountDirIdx = body.range(of: "_account-dir")?.lowerBound
        #expect(helpIdx != nil, "use) should check for --help")
        if let h = helpIdx, let a = accountDirIdx {
            #expect(h < a, "--help short-circuit must come BEFORE _account-dir call")
        }
    }
}
