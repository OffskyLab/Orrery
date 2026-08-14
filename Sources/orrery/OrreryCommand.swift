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
        subcommands: OrreryCommand.allSubcommands
    )

    /// Built via a closure (rather than an array literal) so the
    /// macOS-only `AccountAddHealHookCommand` can be conditionally appended
    /// with `#if os(macOS)` — Swift doesn't support `#if` directly around
    /// individual elements of an array literal passed as an argument.
    private static var allSubcommands: [ParsableCommand.Type] {
        var cmds: [ParsableCommand.Type] = [
            UpdateCommand.self,
            SetupCommand.self,
            InitCommand.self,
            AddCommand.self,
            ListCommand.self,
            ShowCommand.self,
            UseCommand.self,
            PinCommand.self,
            RemoveCommand.self,
            WorkspaceCommand.self,
            RunCommand.self,
            DelegateCommand.self,
            SessionsCommand.self,
            MCPSetupCommand.self,
            MCPServerCommand.self,
            SetCurrentCommand.self,
            CheckUpdateCommand.self,
            LinkMemoryCommand.self,
            UninstallCommand.self,
            InstallCommand.self,
            ThirdPartyCommand.self,
            PhantomAccountTriggerCommand.self,
            AccountAddPrepareCommand.self,
            AccountAddFinalizeCommand.self,
            RefreshTokenCommand.self,
            // Internal subcommands (hidden from --help, used by shell wrappers)
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
