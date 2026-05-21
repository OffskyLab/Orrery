import Testing
@testable import OrreryCore

@Suite("ShellFunctionGenerator")
struct ShellFunctionGeneratorTests {

    @Test("output contains orrery shell function definition")
    func containsOrreryFunction() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("orrery()"))
    }

    @Test("output handles 'use' subcommand")
    func handlesUse() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_export"))
        #expect(script.contains("ORRERY_ACTIVE_ENV"))
    }

    @Test("output handles 'deactivate' subcommand")
    func handlesDeactivate() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("deactivate"))
        #expect(script.contains("orrery use origin"))
    }

    @Test("output auto-activates current environment on shell start")
    func autoActivatesCurrent() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_orrery_init"))
        #expect(script.contains("current"))
    }

    @Test("phantom loop applies a target account from the sentinel")
    func phantomLoopAppliesTargetAccount() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("TARGET_ACCOUNT_TOOL"))
        #expect(script.contains("TARGET_ACCOUNT_NAME"))
        #expect(script.contains("account use --\"$TARGET_ACCOUNT_TOOL\" --name \"$TARGET_ACCOUNT_NAME\""))
    }

    @Test("account add --claude routes through shell function with TTY-attached claude")
    func accountAddClaudeRoutesThroughShell() {
        let script = ShellFunctionGenerator.generate()
        // The account) case must be present.
        #expect(script.contains("account)"))
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
        #expect(script.contains("-h|--help) command orrery-bin account \"$@\"; return $?"))
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
