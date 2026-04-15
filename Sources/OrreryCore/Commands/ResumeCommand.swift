import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ResumeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: L10n.Resume.abstract,
        discussion: "With no index: interactive picker. Example: orrery resume 1 --dangerously-skip-permissions"
    )

    @Flag(help: ArgumentHelp(L10n.ToolFlag.claude))
    public var claude: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))
    public var codex: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini))
    public var gemini: Bool = false

    @Argument(parsing: .allUnrecognized)
    public var remaining: [String] = []

    public init() {}

    public func run() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let store = EnvironmentStore.default

        // Split remaining into: optional numeric index + passthrough flags
        let indexStr = remaining.first(where: { !$0.hasPrefix("-") && Int($0) != nil })
        let passthrough = remaining.filter { $0 != indexStr }

        if let indexStr, let index = Int(indexStr), index > 0 {
            // --- Direct resume by index (single-tool) ---
            let tool = resolvedTool()
            let entries = SessionsCommand.findSessions(tool: tool, cwd: cwd, store: store)
                .sorted { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }
            guard index <= entries.count else {
                throw ValidationError(L10n.Resume.indexOutOfRange(index, entries.count))
            }
            try Self.executeResume(tool: tool, sessionId: entries[index - 1].id, passthrough: passthrough, store: store)
        } else {
            // --- Interactive picker ---
            // Picker uses /dev/tty directly; check it's openable before proceeding.
            let ttyCheck = Darwin.open("/dev/tty", O_RDWR)
            guard ttyCheck >= 0 else {
                throw ValidationError(L10n.Resume.noIndex)
            }
            Darwin.close(ttyCheck)

            let tools: [Tool]
            if claude { tools = [.claude] } else if codex { tools = [.codex] } else if gemini { tools = [.gemini] } else { tools = Tool.allCases }

            // Show indicator before reading session files — discovery can be slow
            // (many large JSONL files) and the terminal would otherwise appear frozen.
            let fh = FileHandle.standardOutput
            fh.write(Data("Loading sessions…".utf8))

            let activeIds = SessionsCommand.activeClaudeSessionIds(store: store)

            var items: [SessionsCommand.SessionItem] = []
            for tool in tools {
                for var entry in SessionsCommand.findSessions(tool: tool, cwd: cwd, store: store) {
                    entry.isActive = activeIds.contains(entry.id)
                    items.append(SessionsCommand.SessionItem(tool: tool, entry: entry))
                }
            }
            items.sort { ($0.entry.lastTime ?? .distantPast) > ($1.entry.lastTime ?? .distantPast) }

            // Clear the loading line before showing the picker (or the noSessions message).
            fh.write(Data("\r\u{1B}[2K".utf8))

            guard !items.isEmpty else {
                print(L10n.Sessions.noSessions)
                return
            }

            let df = DateFormatter()
            df.dateFormat = "M/d HH:mm"
            let indexWidth = String(items.count).count
            let options = items.enumerated().map { (i, item) -> String in
                let n = String(i + 1)
                let idx = String(repeating: " ", count: indexWidth - n.count) + n
                // Color-coded tool tag: orange=claude, green=gemini, dark-gray=codex
                let tag = "[\(item.tool.rawValue)]".padding(toLength: 9, withPad: " ", startingAt: 0)
                let ansi: String
                switch item.tool {
                case .claude: ansi = "\u{1B}[33m"   // orange/yellow
                case .gemini: ansi = "\u{1B}[32m"   // green
                case .codex:  ansi = "\u{1B}[90m"   // dark gray
                }
                let toolTag = "\(ansi)\(tag)\u{1B}[0m"
                let timeStr = (item.entry.lastTime.map { df.string(from: $0) } ?? "?")
                    .padding(toLength: 11, withPad: " ", startingAt: 0)
                let msgs = "\(item.entry.userCount) msgs"
                    .padding(toLength: 8, withPad: " ", startingAt: 0)
                let activeMark = item.entry.isActive ? "\u{1B}[32m▶\u{1B}[0m " : "  "
                let shortId = "\u{1B}[2m\(item.entry.id.prefix(8))\u{1B}[0m"
                let title = String(item.entry.firstMessage.prefix(40))
                return "\(idx). \(toolTag) \(timeStr) \(msgs) \(activeMark)\(shortId) \(title)"
            }

            let selector = SingleSelect(title: L10n.Resume.pickerTitle(items.count), options: options)
            guard let choice = selector.runOrNil() else { return }

            let chosen = items[choice]
            if chosen.entry.isActive {
                print("\u{1B}[33mWarning: this session is already running in another window.\u{1B}[0m")
            }
            try Self.executeResume(tool: chosen.tool, sessionId: chosen.entry.id, passthrough: passthrough, store: store)
        }
    }

    /// Spawn the underlying tool's resume command for a given session under the
    /// currently active orrery env. Throws `ExitCode` to propagate the child's
    /// exit status to the caller.
    public static func executeResume(
        tool: Tool,
        sessionId: String,
        passthrough: [String],
        store: EnvironmentStore
    ) throws {
        var command: [String]
        switch tool {
        case .claude: command = ["claude", "--resume", sessionId]
        case .codex:  command = ["codex", "resume", sessionId]
        case .gemini: command = ["gemini", "--resume", sessionId]
        }
        command += passthrough

        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        var processEnv = ProcessInfo.processInfo.environment
        if let envName, envName != ReservedEnvironment.defaultName {
            let env = try store.load(named: envName)
            for t in env.tools {
                processEnv[t.envVarName] = store.toolConfigDir(tool: t, environment: envName).path
            }
        }

        // Strip IPC variables that make claude think it's a subprocess and hang.
        processEnv.removeValue(forKey: "CLAUDECODE")
        processEnv.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        processEnv.removeValue(forKey: "CLAUDE_CODE_EXECPATH")

        // Replace this process with the tool via execvp — inherits full TTY cleanly.
        for (key, value) in processEnv {
            setenv(key, value, 1)
        }
        let argv = command.map { strdup($0) } + [nil]
        execvp(command[0], argv)

        // execvp only returns on failure.
        perror("execvp")
        throw ExitCode.failure
    }

    private func resolvedTool() -> Tool {
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude
    }
}
