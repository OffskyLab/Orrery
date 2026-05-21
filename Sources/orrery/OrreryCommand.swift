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
        subcommands: [
            UpdateCommand.self,
            SetupCommand.self,
            InitCommand.self,
            UseCommand.self,
            CreateCommand.self,
            AccountCommand.self,
            DeleteCommand.self,
            RenameCommand.self,
            ListCommand.self,
            InfoCommand.self,
            EnvCommand.self,
            ToolsCommand.self,
            CurrentCommand.self,
            WhichCommand.self,
            RunCommand.self,
            ResumeCommand.self,
            DelegateCommand.self,
            SessionsCommand.self,
            MemoryCommand.self,
            MCPSetupCommand.self,
            MCPServerCommand.self,
            ExportCommand.self,
            UnexportCommand.self,
            SetCurrentCommand.self,
            CheckUpdateCommand.self,
            LinkMemoryCommand.self,
            SyncCommand.self,
            OriginCommand.self,
            UninstallCommand.self,
            AuthCommand.self,
            InstallCommand.self,
            ThirdPartyCommand.self,
            PhantomTriggerCommand.self,
            PhantomAccountTriggerCommand.self,
            MaterializeCommand.self,
            SyncBackCommand.self,
        ]
    )
    public init() {}
}
