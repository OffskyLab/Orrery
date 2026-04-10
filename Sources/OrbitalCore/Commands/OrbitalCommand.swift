import ArgumentParser

public struct OrbitalCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "orbital",
        abstract: L10n.Orbital.abstract,
        version: "1.0.5",
        subcommands: [
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
            SyncCommand.self,
        ]
    )
    public init() {}
}
