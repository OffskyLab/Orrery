import ArgumentParser
import Foundation

public struct OriginCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "origin",
        abstract: L10n.Origin.abstract,
        subcommands: [
            StatusSubcommand.self,
            TakeoverSubcommand.self,
            ReleaseSubcommand.self,
        ],
        defaultSubcommand: StatusSubcommand.self
    )
    public init() {}

    // MARK: - status

    public struct StatusSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: L10n.Origin.statusAbstract
        )
        public init() {}

        public func run() {
            let store = EnvironmentStore.default
            for tool in Tool.allCases {
                if store.isOriginManaged(tool: tool) {
                    let path = store.originConfigDir(tool: tool).path
                    print("  \(tool.rawValue): \u{1B}[32mmanaged\u{1B}[0m  →  \(path)")
                } else {
                    let path = tool.defaultConfigDir.path
                    print("  \(tool.rawValue): \u{1B}[2munmanaged\u{1B}[0m  (\(path))")
                }
            }
        }
    }

    // MARK: - takeover

    public struct TakeoverSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "takeover",
            abstract: L10n.Origin.takeoverAbstract
        )
        @Flag(help: ArgumentHelp(L10n.ToolFlag.claude)) public var claude: Bool = false
        @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))  public var codex: Bool = false
        @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini)) public var gemini: Bool = false
        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            for tool in resolvedTools() {
                if store.isOriginManaged(tool: tool) {
                    print(L10n.Origin.alreadyManaged(tool.rawValue))
                    continue
                }
                try store.originTakeover(tool: tool)
                print(L10n.Origin.tookOver(tool.rawValue, store.originConfigDir(tool: tool).path))
            }
            print(L10n.Origin.hint)
        }

        private func resolvedTools() -> [Tool] {
            let selected = [(claude, Tool.claude), (codex, .codex), (gemini, .gemini)]
                .filter(\.0).map(\.1)
            return selected.isEmpty ? Tool.allCases : selected
        }
    }

    // MARK: - release

    public struct ReleaseSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "release",
            abstract: L10n.Origin.releaseAbstract
        )
        @Flag(help: ArgumentHelp(L10n.ToolFlag.claude)) public var claude: Bool = false
        @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))  public var codex: Bool = false
        @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini)) public var gemini: Bool = false
        public init() {}

        public func run() throws {
            let store = EnvironmentStore.default
            var anyDone = false
            for tool in resolvedTools() {
                if !store.isOriginManaged(tool: tool) {
                    print(L10n.Origin.alreadyUnmanaged(tool.rawValue))
                    continue
                }
                try store.originRelease(tool: tool)
                print(L10n.Origin.released(tool.rawValue, tool.defaultConfigDir.path))
                anyDone = true
            }
            if !anyDone {
                print(L10n.Origin.nothingToRelease)
            }
        }

        private func resolvedTools() -> [Tool] {
            let selected = [(claude, Tool.claude), (codex, .codex), (gemini, .gemini)]
                .filter(\.0).map(\.1)
            return selected.isEmpty ? Tool.allCases : selected
        }
    }
}
