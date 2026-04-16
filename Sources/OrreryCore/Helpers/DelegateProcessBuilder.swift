import ArgumentParser
import Foundation

public enum StdinMode {
    case nullDevice
    case interactive
    case injectedThenInteractive(String)
}

public enum OutputMode {
    case passthrough
    case capture
}

public struct DelegateProcessBuilder {
    public let tool: Tool
    public let prompt: String?
    public let resumeSessionId: String?
    public let environment: String?
    public let store: EnvironmentStore

    public init(tool: Tool, prompt: String?, resumeSessionId: String?,
                environment: String?, store: EnvironmentStore) {
        self.tool = tool
        self.prompt = prompt
        self.resumeSessionId = resumeSessionId
        self.environment = environment
        self.store = store
    }

    public func build(outputMode: OutputMode = .passthrough) throws -> (process: Process, stdinMode: StdinMode, outputPipe: Pipe?) {
        // Build command array
        let command: [String]
        switch (tool, resumeSessionId, prompt) {
        case (.claude, let id?, let p?):
            command = ["claude", "-p", "--resume", id, p, "--allowedTools", "Bash"]
        case (.claude, let id?, nil):
            command = ["claude", "--resume", id]
        case (.claude, nil, let p?):
            command = ["claude", "-p", p, "--allowedTools", "Bash"]
        case (.codex, let id?, let p?):
            command = ["codex", "exec", "resume", id, p]
        case (.codex, let id?, nil):
            command = ["codex", "exec", "resume", id]
        case (.codex, nil, let p?):
            command = ["codex", "exec", p]
        case (.gemini, let id?, let p?):
            command = ["gemini", "--resume", id, "-p", p]
        case (.gemini, let id?, nil):
            command = ["gemini", "--resume", id]
        case (.gemini, nil, let p?):
            command = ["gemini", "-p", p]
        default:
            fatalError("unreachable: guard in DelegateCommand prevents both nil")
        }

        // Determine stdin mode
        let stdinMode: StdinMode
        if resumeSessionId != nil && prompt == nil {
            stdinMode = .interactive
        } else {
            stdinMode = .nullDevice
        }

        // Build process environment (full port from DelegateCommand)
        let envName = environment
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
                // through to its own Keychain/encrypted-file lookup.
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
        // When using the default environment, strip all tool config dir vars
        if let envName, envName == ReservedEnvironment.defaultName {
            for t in Tool.allCases {
                processEnv.removeValue(forKey: t.envVarName)
            }
        }

        // Build process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = processEnv
        let outputPipe: Pipe?
        switch outputMode {
        case .capture:
            let pipe = Pipe()
            process.standardOutput = pipe
            outputPipe = pipe
        case .passthrough:
            process.standardOutput = FileHandle.standardOutput
            outputPipe = nil
        }
        process.standardError = FileHandle.standardError

        // Set standardInput based on stdinMode (builder owns this)
        switch stdinMode {
        case .nullDevice:
            process.standardInput = FileHandle.nullDevice
        case .interactive:
            process.standardInput = FileHandle.standardInput
        case .injectedThenInteractive:
            throw ValidationError("stdin injection not yet implemented")
        }

        return (process, stdinMode, outputPipe)
    }
}
