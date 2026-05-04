import ArgumentParser
import OrreryCore

public enum OrreryVersion {
    public static let current = "2.6.2"
}

/// Root CLI command. Lives in the executable target.
///
/// `orrery magi` / `spec` / `spec-run` / `_spec-finalize` are intercepted
/// in `main.swift` and forwarded to the external `orrery-magi` sidecar
/// binary before ArgumentParser sees them, so none of those subcommands are
/// registered here.
public struct OrreryCommand: ParsableCommand {
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
        ]
    )
    public init() {}
}
