import Foundation

/// Automatically takes over unmanaged tool configs on every orrery invocation,
/// unless the user has explicitly opted out (via `orrery origin release` or
/// `orrery uninstall`, which write `~/.orrery/.no-origin-takeover`).
///
/// Skipped when:
/// - the opt-out marker is present
/// - the current subcommand is `origin release` / `uninstall` (avoid re-taking
///   over in the same process that is about to release)
public enum OriginTakeoverBootstrap {
    public static func runIfNeeded() {
        let store = EnvironmentStore.default
        guard !store.isOriginTakeoverOptedOut else { return }
        guard !isReleasingOrUninstalling() else { return }

        for tool in Tool.allCases {
            guard !store.isOriginManaged(tool: tool),
                  FileManager.default.fileExists(atPath: tool.defaultConfigDir.path)
            else { continue }
            try? store.originTakeover(tool: tool)
        }
    }

    /// Returns true if the current invocation should skip the bootstrap takeover.
    private static func isReleasingOrUninstalling() -> Bool {
        let args = CommandLine.arguments.dropFirst()   // drop binary path
        let subcommands = args.filter { !$0.hasPrefix("-") }
        // orrery origin release — avoid immediately re-taking over what's being released
        if subcommands.first == "origin" && subcommands.dropFirst().first == "release" { return true }
        // orrery uninstall — same reason
        if subcommands.first == "uninstall" { return true }
        // orrery setup — handles takeover itself with interactive prompts; skip silent bootstrap
        if subcommands.first == "setup" { return true }
        return false
    }
}
