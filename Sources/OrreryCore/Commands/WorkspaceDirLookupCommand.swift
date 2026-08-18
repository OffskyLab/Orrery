import ArgumentParser
import Foundation

/// Internal subcommand used by the statusline dispatcher (and anything else
/// that needs to resolve a workspace *name* to its on-disk tool config dir)
/// without duplicating `EnvironmentStore`'s UUID-scan resolution logic in
/// another language.
///
/// `orrery-bin _workspace-dir <name> [--claude|--codex|--gemini]`
///
/// Prints the absolute path of `<workspace>/<tool>` (e.g. the workspace's
/// `claude/` dir, which holds the shared `statusline.js`) if the workspace
/// exists and has that tool's dir. Exits non-zero with a clear error
/// otherwise.
public struct WorkspaceDirLookupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_workspace-dir",
        abstract: "(internal) Print a workspace's tool config dir path, or exit non-zero.",
        shouldDisplay: false
    )

    @Argument(help: ArgumentHelp("Workspace name."))
    public var name: String

    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagClaudeHelp))
    public var claude: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagCodexHelp))
    public var codex: Bool = false
    @Flag(name: .long, help: ArgumentHelp(L10n.Account.flagGeminiHelp))
    public var gemini: Bool = false

    public init() {}

    public func run() throws {
        let selected: [Tool] = [claude ? Tool.claude : nil,
                                codex ? Tool.codex : nil,
                                gemini ? Tool.gemini : nil].compactMap { $0 }
        guard selected.count <= 1 else {
            throw ValidationError("Pass at most one of --claude, --codex, --gemini.")
        }
        let tool: Tool = selected.first ?? .claude

        let envStore = EnvironmentStore.default
        let dir: URL
        if name == Workspace.reservedOriginName {
            // origin is reserved and always resolvable, even before its
            // `workspace.json` has ever been written (fresh installs) —
            // mirrors `loadOriginWorkspace()`'s graceful default.
            dir = envStore.originConfigDir(tool: tool)
        } else {
            do {
                dir = try envStore.envDir(for: name).appendingPathComponent(tool.subdirectory)
            } catch {
                throw ValidationError("Workspace '\(name)' not found.")
            }
        }

        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw ValidationError("Workspace '\(name)' has no \(tool.rawValue) dir yet.")
        }

        print(dir.path)
    }
}
