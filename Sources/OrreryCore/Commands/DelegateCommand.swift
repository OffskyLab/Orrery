import ArgumentParser
import Foundation

public struct DelegateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delegate",
        abstract: L10n.Delegate.abstract,
        discussion: "Example: orrery delegate --claude -e work \"check error handling\""
    )

    @Flag(help: ArgumentHelp(L10n.ToolFlag.claude))
    public var claude: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.codex))
    public var codex: Bool = false

    @Flag(help: ArgumentHelp(L10n.ToolFlag.gemini))
    public var gemini: Bool = false

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Delegate.envHelp))
    public var environment: String?

    @Argument(help: ArgumentHelp(L10n.Delegate.promptHelp))
    public var prompt: String

    public init() {}

    public func run() throws {
        let tool = resolvedTool()
        let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

        let store = EnvironmentStore.default

        // Build environment variables
        var envVars: [String: String] = [:]
        if let envName, envName != ReservedEnvironment.defaultName {
            let env = try store.load(named: envName)
            for t in env.tools {
                envVars[t.envVarName] = store.toolConfigDir(tool: t, environment: envName).path
            }
            for (key, value) in env.env {
                envVars[key] = value
            }
            // gemini-cli ignores GEMINI_CONFIG_DIR and always reads ~/.gemini/,
            // so when delegating to gemini we override HOME to a per-env wrapper
            // whose `.gemini` symlinks back to the env's gemini config.
            if tool == .gemini, env.tools.contains(.gemini) {
                try store.ensureGeminiHomeWrapper(envName: envName)
                envVars["HOME"] = store.geminiHomeDir(environment: envName).path
                // For API-key auth, gemini-cli's non-interactive validator
                // only looks at `process.env.GEMINI_API_KEY` and won't fall
                // through to its own Keychain/encrypted-file lookup. Pre-extract
                // the stored key so `gemini -p` passes validation.
                if envVars["GEMINI_API_KEY"] == nil,
                   ProcessInfo.processInfo.environment["GEMINI_API_KEY"] == nil {
                    let configDir = store.toolConfigDir(tool: .gemini, environment: envName)
                    if let key = GeminiCredentials.loadAPIKey(configDir: configDir) {
                        envVars["GEMINI_API_KEY"] = key
                    }
                }
            }
        }

        var processEnv = ProcessInfo.processInfo.environment
        // Strip inherited API key so the environment's own credentials take effect
        if let envName, envName != ReservedEnvironment.defaultName {
            processEnv.removeValue(forKey: "ANTHROPIC_API_KEY")
        }
        for (key, value) in envVars {
            processEnv[key] = value
        }
        // Strip IPC variables to prevent child claude from hanging
        processEnv.removeValue(forKey: "CLAUDECODE")
        processEnv.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        processEnv.removeValue(forKey: "CLAUDE_CODE_EXECPATH")
        if let envName, envName == ReservedEnvironment.defaultName {
            for t in Tool.allCases {
                processEnv.removeValue(forKey: t.envVarName)
            }
        }

        let command: [String]
        switch tool {
        case .claude: command = ["claude", "-p", prompt, "--allowedTools", "Bash"]
        case .codex:  command = ["codex", "exec", prompt]
        case .gemini: command = ["gemini", "-p", prompt]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = processEnv
        // Redirect stdin to /dev/null so the delegated tool doesn't wait for input
        // it'll never use — `claude -p`, `codex exec`, and `gemini -p` all take the
        // prompt as an arg. With inherited stdin, a non-TTY caller (another script,
        // an SSH session without a pty, the MCP server) triggers Claude's
        // "no stdin data received in 3s" warning and adds 3s latency.
        process.standardInput = FileHandle.nullDevice

        // Pipe stdout/stderr through readabilityHandler rather than inheriting
        // FileHandle.standardOutput directly. When orrery is called as a Bash tool
        // by Claude Code, our own stdout is a pipe whose buffer is ~64 KB. A
        // delegate session (code review, long task) can easily emit more than that
        // before it finishes. With inherited handles, write() in the child blocks
        // once the buffer is full, waitUntilExit() never returns, and all three
        // processes deadlock. Draining via readabilityHandler keeps the buffer clear.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outFH = FileHandle.standardOutput
        let errFH = FileHandle.standardError
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty { outFH.write(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty { errFH.write(data) }
        }

        try process.run()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Flush any remaining bytes after the handler is removed.
        let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingOut.isEmpty { outFH.write(remainingOut) }
        let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingErr.isEmpty { errFH.write(remainingErr) }

        throw ExitCode(process.terminationStatus)
    }

    private func resolvedTool() -> Tool {
        if codex { return .codex }
        if gemini { return .gemini }
        return .claude
    }
}
