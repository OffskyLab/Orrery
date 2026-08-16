import Testing
@testable import OrreryCore

@Suite("PhantomLaunchPolicy")
struct PhantomLaunchPolicyTests {
    private func decide(_ args: [String], tty: Bool = true) -> Bool {
        PhantomLaunchPolicy.shouldSupervise(args: args, stdinIsTTY: tty, stdoutIsTTY: tty)
    }

    @Test("a bare interactive launch is supervised")
    func bareLaunch() {
        #expect(decide([]))
    }

    @Test("an interactive launch with an initial prompt is supervised")
    func initialPrompt() {
        #expect(decide(["explain this repo"]))
    }

    @Test("--resume is supervised — it is still an interactive session")
    func resumeIsSupervised() {
        #expect(decide(["--resume", "abc-123"]))
    }

    @Test("-p is not supervised: one-shot non-interactive mode")
    func shortPrintFlag() {
        #expect(!decide(["-p", "hello"]))
    }

    @Test("--print is not supervised")
    func longPrintFlag() {
        #expect(!decide(["--print", "hello"]))
    }

    @Test("non-session subcommands are not supervised")
    func subcommands() {
        for sub in ["mcp", "update", "doctor", "config", "install",
                    "plugin", "setup-token", "migrate-installer"] {
            #expect(!decide([sub]), "\(sub) should not be supervised")
        }
    }

    @Test("a subcommand behind a global flag is supervised — first-arg-only is deliberate")
    func subcommandAfterFlagIsSupervised() {
        // Not the behaviour a whitelist scanner would give, and that is fine:
        // erring toward supervising costs one registry entry, because the loop
        // exits on the first _phantom-next with no sentinel.
        #expect(decide(["--debug", "mcp", "list"]))
    }

    @Test("a flag's value is not mistaken for a subcommand")
    func flagValueIsNotASubcommand() {
        // `--model config` must not be read as the `config` subcommand.
        #expect(decide(["--model", "config"]))
    }

    @Test("non-tty stdin is not supervised (piped input)")
    func pipedStdin() {
        #expect(!PhantomLaunchPolicy.shouldSupervise(
            args: [], stdinIsTTY: false, stdoutIsTTY: true))
    }

    @Test("non-tty stdout is not supervised (output redirected)")
    func redirectedStdout() {
        #expect(!PhantomLaunchPolicy.shouldSupervise(
            args: [], stdinIsTTY: true, stdoutIsTTY: false))
    }

    @Test("a subcommand's own arguments do not change the decision")
    func subcommandWithArguments() {
        #expect(!decide(["mcp", "list"]))
        #expect(!decide(["config", "get", "theme"]))
    }

    @Test("a value-taking flag with no value does not crash the scan")
    func truncatedFlag() {
        #expect(decide(["--model"]))
    }
}
