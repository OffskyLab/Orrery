import Testing
@testable import OrreryCore

@Suite("ShellFunctionGenerator")
struct ShellFunctionGeneratorTests {

    @Test("output contains orrery shell function definition")
    func containsOrreryFunction() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("orrery()"))
    }

    @Test("output handles top-level 'enter' subcommand")
    func handlesEnter() {
        let script = ShellFunctionGenerator.generate()
        // Top-level enter) case exists.
        #expect(script.contains("\n    enter)\n"))
        // Same shell-side export pipeline that sandbox use had.
        #expect(script.contains("sandbox _export"))
        #expect(script.contains("ORRERY_ACTIVE_ENV"))
    }

    @Test("output handles top-level 'exit' subcommand")
    func handlesExit() {
        let script = ShellFunctionGenerator.generate()
        // Top-level exit) case exists.
        #expect(script.contains("\n    exit)\n"))
        // exit clears tool env vars and writes ORRERY_ACTIVE_ENV=origin.
        #expect(script.contains("unset CLAUDE_CONFIG_DIR CODEX_HOME CODEX_CONFIG_DIR GEMINI_CONFIG_DIR ORRERY_GEMINI_HOME"))
        #expect(script.contains("export ORRERY_ACTIVE_ENV=\"origin\""))
    }

    @Test("enter rejects 'origin' and points the user at exit")
    func enterRejectsOrigin() {
        let script = ShellFunctionGenerator.generate()
        // The enter case must check for "$1" = "origin" and surface the L10n message.
        #expect(script.contains("\"$1\" = \"origin\""))
        #expect(script.contains(L10n.Enter.cannotEnterOrigin))
    }

    @Test("output auto-activates current sandbox on shell start")
    func autoActivatesCurrent() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_orrery_init"))
        #expect(script.contains("current"))
        // Init must call `orrery sandbox use` (not bare `orrery use`) so the
        // shell-side env-var exports for the active sandbox actually run.
        #expect(script.contains("orrery sandbox use \"$env_name\""))
    }

    @Test("phantom loop applies a target account from the sentinel")
    func phantomLoopAppliesTargetAccount() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("TARGET_ACCOUNT_TOOL"))
        #expect(script.contains("TARGET_ACCOUNT_NAME"))
        #expect(script.contains("account use --\"$TARGET_ACCOUNT_TOOL\" --name \"$TARGET_ACCOUNT_NAME\""))
    }

    @Test("orrery add --claude routes through shell function with TTY-attached claude")
    func addClaudeRoutesThroughShell() {
        let script = ShellFunctionGenerator.generate()
        // The add) case must be present (was account) before v3).
        #expect(script.contains("add)"))
        // The old account) dispatcher must be gone.
        #expect(!script.contains("            account)"))
        // Claude detection logic.
        #expect(script.contains("_is_claude=1"))
        #expect(script.contains("--codex|--gemini"))
        // Prepare / claude / finalize pipeline.
        #expect(script.contains("_account-add-prepare"))
        #expect(script.contains("command claude"))
        #expect(script.contains("_account-add-finalize"))
        // Login ready hint is printed before claude launches.
        #expect(script.contains(L10n.Account.loginReadyHint))
    }

    @Test("account add -h bypasses the claude TTY interception")
    func accountAddHelpBypassesInterception() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("-h|--help) command orrery-bin \"$@\"; return $?"))
        // Negative: no double-account prefix
        #expect(!script.contains("-h|--help) command orrery-bin account \"$@\""))
    }

    @Test("account add --codex and --gemini fall through to orrery-bin, not claude")
    func accountAddCodexGeminiFallThrough() {
        let script = ShellFunctionGenerator.generate()
        // The non-claude path must fall through to orrery-bin "$@".
        #expect(script.contains("command orrery-bin \"$@\""))
        // The detection logic must check for --codex and --gemini flags.
        #expect(script.contains("--codex|--gemini) _is_claude=0"))
    }
}
