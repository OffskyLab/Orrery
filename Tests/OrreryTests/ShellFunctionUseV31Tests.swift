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
        let body = String(sh[useStart.upperBound...].prefix(2500))
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
        let body = String(sh[useStart.upperBound...].prefix(2500))
        #expect(body.contains("export CLAUDE_CONFIG_DIR"),
            "use) should export CLAUDE_CONFIG_DIR when v3.1 lookup succeeds")
    }

    @Test("use) tries the v3.1 fast path for --codex, exporting CODEX_HOME")
    func codexTriesFastPath() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(2500))
        #expect(body.contains("_is_codex"), "use) should detect --codex explicitly")
        #expect(body.contains("export CODEX_HOME"),
            "use) should export CODEX_HOME when the codex account-dir lookup succeeds")
        // Falls back to the legacy binary path for accounts not yet migrated.
        #expect(body.contains("command orrery-bin use"),
            "use) should fall back to orrery-bin use for unmigrated codex accounts")
    }

    @Test("use) tries the v3.1 fast path for --gemini, exporting ORRERY_GEMINI_HOME")
    func geminiTriesFastPath() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(2500))
        #expect(body.contains("_is_gemini"), "use) should detect --gemini explicitly")
        // gemini-cli ignores GEMINI_CONFIG_DIR, so the fast path must export
        // ORRERY_GEMINI_HOME (consumed by the gemini() wrapper's HOME override),
        // not GEMINI_CONFIG_DIR directly.
        #expect(body.contains("export ORRERY_GEMINI_HOME"),
            "use) should export ORRERY_GEMINI_HOME when the gemini account-dir lookup succeeds")
        #expect(!body.contains("export GEMINI_CONFIG_DIR"),
            "gemini-cli ignores GEMINI_CONFIG_DIR — exporting it would silently do nothing")
        // Falls back to the legacy binary path for accounts not yet migrated.
        #expect(body.contains("command orrery-bin use"),
            "use) should fall back to orrery-bin use for unmigrated gemini accounts")
    }

    @Test("use) does NOT silently swallow _account-dir errors for claude")
    func surfacesAccountDirErrors() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(2500))
        // The claude branch specifically must not silence _account-dir's error —
        // it's terminal there (no fallback), so the user needs to see it.
        guard let claudeIdx = body.range(of: "# Claude (explicit or default)") else {
            Issue.record("expected a claude branch comment splitting it from codex")
            return
        }
        // Bounded to the rest of the use) case only — a wider slice would
        // reach into _orrery_init's unrelated self-update check, which also
        // uses 2>/dev/null for an unrelated reason.
        let claudeBranch = String(body[claudeIdx.upperBound...].prefix(400))
        #expect(!claudeBranch.contains("2>/dev/null"),
            "the claude branch of use) must not silence _account-dir errors with 2>/dev/null")
        #expect(claudeBranch.contains(">&2") || claudeBranch.contains("return 1"),
            "use) should surface _account-dir errors and return non-zero for claude")
    }

    @Test("use) bypasses v3.1 fast-path for --help / --version")
    func bypassesHelpVersion() {
        let sh = ShellFunctionGenerator.generate()
        guard let useStart = sh.range(of: "use)") else {
            Issue.record("use) case not found")
            return
        }
        let body = String(sh[useStart.upperBound...].prefix(2500))
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
