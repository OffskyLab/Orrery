import ArgumentParser

public struct OrbitalCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "orbital",
        abstract: L10n.Orbital.abstract,
        version: "0.3.3",
        subcommands: [
            SetupCommand.self,
            InitCommand.self,
            UseCommand.self,
            CreateCommand.self,
            DeleteCommand.self,
            RenameCommand.self,
            ListCommand.self,
            InfoCommand.self,
            SetEnvCommand.self,
            UnsetEnvCommand.self,
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
