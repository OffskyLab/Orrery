import ArgumentParser
import OrreryCore

/// Root CLI command. Lives in the executable target.
///
/// `orrery magi` / `spec` / `spec-run` / `_spec-finalize` are intercepted
/// in `main.swift` and forwarded to the external `orrery-magi` sidecar
/// binary before ArgumentParser sees them, so none of those subcommands are
/// registered here.
public struct OrreryCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "orrery",
        abstract: L10n.Orrery.abstract,
        version: OrreryVersion.current,
        subcommands: OrreryCommand.hiddenSubcommands,
        groupedSubcommands: OrreryCommand.visibleSubcommandGroups
    )

    /// Grouped so `--help` reads as sections instead of one flat list.
    private static var visibleSubcommandGroups: [CommandGroup] {
        [
            CommandGroup(name: "Accounts", subcommands: [
                AddCommand.self,
                ListCommand.self,
                ShowCommand.self,
                UseCommand.self,
                PinCommand.self,
                RemoveCommand.self,
                RefreshTokenCommand.self,
            ]),
            CommandGroup(name: "Workspaces", subcommands: [
                WorkspaceCommand.self,
            ]),
            CommandGroup(name: "Execution", subcommands: [
                RunCommand.self,
                DelegateCommand.self,
                SessionsCommand.self,
                PhantomAccountTriggerCommand.self,
            ]),
            CommandGroup(name: "Integrations", subcommands: [
                MCPSetupCommand.self,
                ThirdPartyCommand.self,
            ]),
            CommandGroup(name: "Setup", subcommands: [
                SetupCommand.self,
                InitCommand.self,
                UpdateCommand.self,
                UninstallCommand.self,
            ]),
        ]
    }

    /// Built via a closure (rather than an array literal) so the
    /// macOS-only `AccountAddHealHookCommand` can be conditionally appended
    /// with `#if os(macOS)` — Swift doesn't support `#if` directly around
    /// individual elements of an array literal passed as an argument.
    ///
    /// These all have `shouldDisplay: false`, so they're internal/shell-wrapper
    /// commands rather than part of the user-facing `--help` groups above.
    private static var hiddenSubcommands: [ParsableCommand.Type] {
        var cmds: [ParsableCommand.Type] = [
            MCPServerCommand.self,
            SetCurrentCommand.self,
            CheckUpdateCommand.self,
            LinkMemoryCommand.self,
            AccountAddPrepareCommand.self,
            AccountAddFinalizeCommand.self,
            PrepareClaudeLaunchCommand.self,
            CaptureClaudeExitCommand.self,
            AccountDirLookupCommand.self,
        ]
        #if os(macOS)
        cmds.append(AccountAddHealHookCommand.self)
        #endif
        return cmds
    }
    public init() {}
}
