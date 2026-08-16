import Foundation

/// Decides whether a given `claude` invocation is an interactive session
/// worth supervising.
///
/// This lives in Swift rather than in the generated shell function on
/// purpose: the shell integration is written into the user's rc file and only
/// changes when they re-run `orrery setup`, so anything likely to need
/// updating — like the subcommand list below — belongs behind the binary.
public enum PhantomLaunchPolicy {

    /// `claude` subcommands that do not start a conversation. Supervising one
    /// would relaunch a utility command in a loop.
    public static let nonSessionSubcommands: Set<String> = [
        "mcp", "update", "doctor", "config", "install",
        "plugin", "setup-token", "migrate-installer",
    ]

    /// Flags that take a value, so the token after them must not be read as a
    /// subcommand.
    private static let valueTakingFlags: Set<String> = [
        "--model", "--resume", "-r", "--settings", "--add-dir",
        "--allowed-tools", "--disallowed-tools", "--permission-mode",
        "--append-system-prompt", "--mcp-config", "--session-id",
    ]

    public static func shouldSupervise(
        args: [String],
        stdinIsTTY: Bool,
        stdoutIsTTY: Bool
    ) -> Bool {
        // A supervisor loop only makes sense around an interactive TUI.
        guard stdinIsTTY, stdoutIsTTY else { return false }

        // One-shot print mode exits immediately; relaunching it would loop.
        if args.contains("-p") || args.contains("--print") { return false }

        if let sub = firstPositional(args), nonSessionSubcommands.contains(sub) {
            return false
        }

        return true
    }

    /// The first token that is neither a flag nor a flag's value.
    private static func firstPositional(_ args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if valueTakingFlags.contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            return arg
        }
        return nil
    }
}
