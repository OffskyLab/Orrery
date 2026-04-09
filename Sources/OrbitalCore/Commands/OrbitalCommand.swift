import ArgumentParser

public struct OrbitalCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "orbital",
        abstract: L10n.Orbital.abstract,
        version: "0.2.3",
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
            DelegateCommand.self,
            SessionsCommand.self,
            MCPServerCommand.self,
            ExportCommand.self,
            UnexportCommand.self,
            SetCurrentCommand.self,
        ]
    )
    public init() {}
}
