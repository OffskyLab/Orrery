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
        // Friendly no-op path at origin: emits the alreadyAtOrigin message to
        // stderr and returns 0 instead of erroring. Mirrors enterRejectsOrigin's
        // approach of asserting the L10n constant itself so a translation drift
        // or a removed branch is caught.
        #expect(script.contains(L10n.Exit.alreadyAtOrigin))
        #expect(script.contains("return 0"))
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
        // Init must dispatch through the v3 verbs: origin → exit, other → enter.
        #expect(script.contains("orrery exit >/dev/null 2>&1"))
        #expect(script.contains("orrery enter \"$env_name\" >/dev/null 2>&1"))
        // Old call site is gone.
        #expect(!script.contains("orrery sandbox use \"$env_name\""))
    }

    @Test("phantom loop applies a target account from the sentinel")
    func phantomLoopAppliesTargetAccount() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("TARGET_ACCOUNT_TOOL"))
        #expect(script.contains("TARGET_ACCOUNT_NAME"))
        // v3: the account switcher is the top-level `orrery use`, and the
        // account name is a positional argument — not the v2-era
        // `orrery account use --name <name>`.
        #expect(script.contains("use --\"$TARGET_ACCOUNT_TOOL\" \"$TARGET_ACCOUNT_NAME\""))
        #expect(!script.contains("orrery-bin account use"))
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

    @Test("sandbox)/use) arm is removed from the dispatcher")
    func sandboxUseGone() {
        let script = ShellFunctionGenerator.generate()
        // The nested use) arm under sandbox) must be gone.
        // Match the indented dispatch line specifically so we don't false-match
        // a different "use)" elsewhere.
        #expect(!script.contains("                use)\n"))
        // sandbox)/create) auto-switch must hand off to enter, not sandbox use.
        #expect(!script.contains("orrery sandbox use \"$_name\""))
        #expect(script.contains("orrery enter \"$_name\""))
    }

    @Test("run -e <env> hands the target to orrery enter (or exit for origin)")
    func runUsesEnter() {
        let script = ShellFunctionGenerator.generate()
        // No bare `orrery sandbox use` left in the run case.
        #expect(!script.contains("orrery sandbox use \"$_run_target\""))
        // origin → exit; other → enter. Both branches asserted so a regression
        // that drops either branch is caught — `|| return $?` is unique to the
        // run case (the phantom loop uses `|| break`, init uses `|| true`).
        #expect(script.contains("if [ \"$_run_target\" = \"origin\" ]; then"))
        #expect(script.contains("orrery exit || return $?"))
        #expect(script.contains("orrery enter \"$_run_target\" || return $?"))
    }

    @Test("phantom loop translates TARGET_SANDBOX=origin into orrery exit")
    func phantomLoopTranslatesOrigin() {
        let script = ShellFunctionGenerator.generate()
        // The phantom-supervisor loop must dispatch on TARGET_SANDBOX with an
        // origin → exit fallback so the user can switch back via the slash
        // command without breaking the supervisor. The `|| break` suffix is
        // unique to the phantom loop (the run case uses `|| return $?`, init
        // uses `|| true`), so it pins the assertion to this call site.
        #expect(script.contains("if [ \"$TARGET_SANDBOX\" = \"origin\" ]; then"))
        #expect(script.contains("orrery exit || break"))
        #expect(script.contains("orrery enter \"$TARGET_SANDBOX\" || break"))
        // Old direct call is gone.
        #expect(!script.contains("orrery sandbox use \"$TARGET_SANDBOX\""))
    }
}
