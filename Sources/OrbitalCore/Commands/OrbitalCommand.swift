import ArgumentParser

public struct OrbitalCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "orbital",
        abstract: "AI CLI environment manager — manage accounts for Claude, Codex, Gemini",
        version: "0.1.1",
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
            AddToolCommand.self,
            RemoveToolCommand.self,
            CurrentCommand.self,
            WhichCommand.self,
            ExportCommand.self,
            UnexportCommand.self,
        ]
    )
    public init() {}
}
