import ArgumentParser
import Foundation

/// Internal subcommand invoked from `_orrery_init` on every new shell.
///
/// `orrery-bin _current-export`
///
/// Prints one `export VAR="path"` line (shell-syntax, meant to be `eval`'d)
/// per tool that has a globally-current account pinned (`_pin-current`) and
/// resolvable in the v3.1 layout. A tool is skipped — never printed — when:
/// its export env var is already set in this process's environment (an
/// explicit override in this shell wins), it has no manager registered, it
/// has no pin, or its account dir isn't in v3.1 layout (symlinks missing).
/// All skips are silent: this command must never fail a shell's startup.
public struct CurrentExportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_current-export",
        abstract: "(internal) Print `export VAR=path` lines for the pinned current accounts.",
        shouldDisplay: false
    )

    public init() {}

    public func run() throws {
        let acctStore = AccountStore.default
        let envStore = EnvironmentStore.default
        let origin = envStore.loadOriginWorkspace()

        for tool in Tool.allCases {
            guard let manager = AccountDirectoryRuntime.manager(ifAvailable: tool) else { continue }
            let existing = ProcessInfo.processInfo.environment[manager.exportEnvVarName]
            guard existing == nil || existing!.isEmpty else { continue }

            guard let id = origin.account(for: tool),
                  let acct = try? acctStore.load(id: id, tool: tool)
            else { continue }

            guard manager.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore) == .ok
            else { continue }

            let dir = acctStore.accountDir(id: acct.id, tool: tool)
            guard let exportPath = try? manager.resolvedExportPath(accountDir: dir) else { continue }

            print("export \(manager.exportEnvVarName)=\"\(exportPath.path)\"")
        }
    }
}
