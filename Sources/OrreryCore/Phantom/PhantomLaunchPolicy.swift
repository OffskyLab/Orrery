import Foundation

/// Decides whether a given `claude` invocation is an interactive session
/// worth supervising.
///
/// This lives in Swift rather than in the generated shell function on
/// purpose: the shell integration is written into the user's rc file and only
/// changes when they re-run `orrery setup`, so anything likely to need
/// updating — like the subcommand list below — belongs behind the binary.
///
/// Only the FIRST argument is examined for a subcommand. An earlier design
/// walked the whole argv, skipping each flag's value via a whitelist of
/// value-taking flags; that whitelist has to track another tool's CLI across
/// versions (the real `claude` has 29 such flags, several with two accepted
/// spellings) and was wrong the moment it was written. Checking `args.first`
/// needs no such knowledge, and `claude`'s own subcommands are always the
/// first argument.
///
/// Erring toward "supervise" is cheap: the supervisor loop asks
/// `_phantom-next` whether to continue, and with no sentinel written that
/// answers no, so a wrongly-supervised one-shot command runs exactly once and
/// costs a single registry entry that is immediately removed.
public enum PhantomLaunchPolicy {

    /// `claude` subcommands that do not start a conversation.
    public static let nonSessionSubcommands: Set<String> = [
        "mcp", "update", "doctor", "config", "install",
        "plugin", "setup-token", "migrate-installer",
    ]

    public static func shouldSupervise(
        args: [String],
        stdinIsTTY: Bool,
        outputIsTTY: Bool
    ) -> Bool {
        // A supervisor loop only makes sense around an interactive TUI.
        guard stdinIsTTY, outputIsTTY else { return false }

        // One-shot print mode exits immediately on its own.
        //
        // This matches the token anywhere rather than only in flag position.
        // A value that happens to equal "-p" would therefore suppress
        // supervision — the harmless direction, since the user simply gets an
        // unsupervised claude, and avoiding it would require reintroducing the
        // value-taking-flag whitelist this design deliberately removed.
        if args.contains("-p") || args.contains("--print") { return false }

        if let first = args.first, nonSessionSubcommands.contains(first) {
            return false
        }

        return true
    }
}
