import ArgumentParser
import Foundation

public struct RunCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: L10n.Run.abstract,
        discussion: """
        Examples:
          orrery run -e work claude              # phantom-supervised (default for claude)
          orrery run -e work claude --resume <id>
          orrery run --non-phantom claude        # opt out: single-shot, no supervisor
          orrery run -e work npm install         # non-claude: always single-shot

        With phantom mode (the default for `claude`), Claude can switch orrery
        environments mid-conversation via the /orrery:phantom slash command —
        the supervisor relaunches Claude with the new env active and `--resume`
        so the conversation continues uninterrupted.

        --non-phantom is handled by the orrery shell function (not this binary).
        """
    )

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Run.envHelp))
    public var environment: String?

    @Argument(parsing: .allUnrecognized, help: ArgumentHelp(L10n.Run.commandHelp))
    public var command: [String] = []

    public init() {}

    public func run() throws {
        guard !command.isEmpty else {
            throw ValidationError(L10n.Run.noCommand)
        }

        let store = EnvironmentStore.default
        let envName = environment ?? ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]

        // Build environment variables
        var envVars: [String: String] = [:]
        if let envName, envName != ReservedEnvironment.defaultName {
            let env = try store.load(named: envName)
            for tool in env.tools {
                envVars[tool.envVarName] = store.toolConfigDir(tool: tool, environment: envName).path
            }
            for (key, value) in env.env {
                envVars[key] = value
            }
        }

        // Materialize the pinned account's credentials for the tool being launched.
        if let tool = Tool(rawValue: command[0]) {
            try Self.prepareMaterialize(tool: tool, envName: envName)
        }

        // Run the command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command

        // Inherit current environment + overlay orrery env vars
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
        // If using default, unset tool config dirs
        if let envName, envName == ReservedEnvironment.defaultName {
            for tool in Tool.allCases {
                processEnv.removeValue(forKey: tool.envVarName)
            }
        }
        process.environment = processEnv

        // Use execvp to replace this process — inherits full TTY for interactive tools
        for (key, value) in processEnv {
            setenv(key, value, 1)
        }
        let argv = command.map { strdup($0) } + [nil]
        execvp(command[0], argv)

        // If execvp returns, it failed
        perror("execvp")
        throw ExitCode.failure
    }
}

extension RunCommand {
    /// 啟動工具前：依當前 env / origin 的 pin 把憑證 materialize 到工具會讀的位置。
    /// envName == nil 或 "origin" 視為 origin。
    static func prepareMaterialize(tool: Tool, envName: String?) throws {
        let envStore = EnvironmentStore.default
        let acctStore = AccountStore.default

        let pinnedID: AccountID?
        let configDir: String?
        if let envName, envName != ReservedEnvironment.defaultName {
            let env = try envStore.load(named: envName)
            pinnedID = env.account(for: tool)
            configDir = envStore.toolConfigDir(tool: tool, environment: envName).path
        } else {
            // origin: 工具執行時 config-dir env var 是 unset 的，
            // 所以傳 nil — adapter 會對應到工具預設位置 / 預設 Keychain service。
            pinnedID = envStore.loadOriginConfig().account(for: tool)
            configDir = nil
        }

        guard let id = pinnedID else {
            // 沒釘 account — 不阻擋啟動，讓工具自己處理「未登入」。
            return
        }

        let account = try acctStore.load(id: id, tool: tool)
        try CredentialAdapters.adapter(for: tool).materialize(
            account: account, configDir: configDir, accountStore: acctStore)
    }
}
