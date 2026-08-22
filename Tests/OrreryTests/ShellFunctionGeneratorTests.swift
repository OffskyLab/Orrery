import Testing
@testable import OrreryCore

@Suite("ShellFunctionGenerator")
struct ShellFunctionGeneratorTests {

    @Test("output contains orrery shell function definition")
    func containsOrreryFunction() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("orrery()"))
    }

    @Test("enter/exit/sandbox-level workspace switching is removed")
    func enterExitSandboxGone() {
        let script = ShellFunctionGenerator.generate()
        // Top-level enter)/exit)/sandbox) cases are gone.
        #expect(!script.contains("\n    enter)\n"))
        #expect(!script.contains("\n    exit)\n"))
        #expect(!script.contains("\n    sandbox)\n"))
        #expect(!script.contains("orrery enter"))
        #expect(!script.contains("orrery exit"))
        #expect(!script.contains("orrery-bin sandbox"))
        #expect(!script.contains("ORRERY_ACTIVE_ENV"))
    }

    @Test("shell startup no longer restores a previously-active workspace")
    func initNoLongerRestoresWorkspace() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_orrery_init"))
        // The self-heal read of ~/.orrery/current is gone along with enter/exit.
        #expect(!script.contains("current_file"))
        // The self-update / memory-link responsibilities remain.
        #expect(script.contains("orrery-bin setup"))
        #expect(script.contains("_link-memory"))
    }

    @Test("phantom loop applies account switches via _phantom-next's eval-able output")
    func phantomLoopAppliesTargetAccount() {
        let script = ShellFunctionGenerator.generate()
        // Task 10: the shell no longer sources a TARGET_ACCOUNT_TOOL/NAME
        // sentinel or calls `orrery use` itself — `_phantom-next` resolves
        // the account dir in Swift and prints an `export` line for the
        // claude() shim's loop to `eval`, because a child process can never
        // export into its parent shell any other way.
        #expect(!script.contains("TARGET_ACCOUNT_TOOL"))
        #expect(!script.contains("TARGET_ACCOUNT_NAME"))
        #expect(!script.contains("orrery-bin account use"))
        #expect(script.contains("_phantom-next --id \"$ORRERY_PHANTOM_ID\""))
        #expect(script.contains("eval \"$_next\""))
        // Workspace-switch sentinel field is gone.
        #expect(!script.contains("TARGET_SANDBOX"))
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
        // Login ready hint is printed before claude launches. Purely
        // informational now — the auth_success hook installed by
        // _account-add-prepare finalizes the account automatically as soon
        // as login succeeds, so /exit is offered, not required.
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

    @Test("run -e/--env on phantom claude errors instead of switching workspace")
    func runPhantomClaudeRejectsEnvFlag() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("-e|--env"))
        #expect(script.contains("_run_target"))
        // No workspace switch left in the phantom claude branch — a clear
        // error pointing at `orrery use` instead.
        #expect(script.contains("is not supported for claude"))
        #expect(script.contains("orrery use <account>"))
    }

    @Test("non-phantom run -e still hands the target straight to orrery-bin run")
    func runNonPhantomKeepsEnvFlag() {
        let script = ShellFunctionGenerator.generate()
        // The single-shot fallback path (non-claude / --non-phantom) still
        // supports targeting a specific environment for one-shot execution —
        // that's independent of the removed persistent enter/exit state.
        // `orrery-bin run` itself takes `-a`/`--account`, not `-e` — that was
        // renamed by f41c089. The shell-level `-e`/`--env` flag parsed above
        // is a separate, still-valid user-facing spelling for `orrery run`.
        #expect(script.contains(#"command orrery-bin run -a "$_run_target" "$@""#))
        #expect(!script.contains(#"orrery-bin run -e "$_run_target""#))
    }
}
