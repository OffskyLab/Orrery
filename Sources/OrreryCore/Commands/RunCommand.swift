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

        // Idempotent safety net: `orrery use` already materialized the
        // pinned account's credentials at switch time. This re-asserts them in
        // case the pin changed by some other path before launch.
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
    /// 解析「當前 env / origin 釘在某工具上的 account + 它的 configDir」。
    /// envName == nil 或 "origin" 視為 origin（configDir = nil，工具預設位置）。
    /// 回傳 nil 代表沒有釘任何 account。
    static func resolvePinnedAccount(
        tool: Tool, envName: String?
    ) throws -> (account: Account, configDir: String?)? {
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

        guard let id = pinnedID else { return nil }
        let account = try acctStore.load(id: id, tool: tool)
        return (account, configDir)
    }

    /// 啟動工具前：依當前 env / origin 的 pin 把憑證 materialize 到工具會讀的位置。
    /// envName == nil 或 "origin" 視為 origin。
    ///
    /// v3.1 起，Claude 的 oauthAccount 由 PrepareClaudeLaunchCommand 透過
    /// claude-identity.json + shared.json merge 寫入 active `.claude.json`，
    /// 不再由 RunCommand 處理 snapshot 注入。
    static func prepareMaterialize(tool: Tool, envName: String?) throws {
        if tool == .claude {
            // v3.1: claude is managed by the shell function wrapper + per-account
            // dir layout — no binary-side prep needed.
            return
        }
        guard let (account, configDir) = try resolvePinnedAccount(tool: tool, envName: envName) else {
            // 沒釘 account — 不阻擋啟動，讓工具自己處理「未登入」。
            return
        }
        let acctStore = AccountStore.default
        try CredentialAdapters.adapter(for: tool).materialize(
            account: account, configDir: configDir, accountStore: acctStore)
    }

    /// 工具結束後：把工具可能 refresh 過的憑證寫回 pool account。
    /// envName == nil 或 "origin" 視為 origin。沒釘 account 時為 no-op。
    ///
    /// v3.1 起，Claude 的 oauthAccount capture 由 CaptureClaudeExitCommand
    /// 透過 claude-identity.json 處理，不再由 RunCommand 捕 pool snapshot。
    /// 之後刷新 account 上的 `email` / `plan` 反映剛剛可能更新的訂閱資訊。
    static func prepareSyncBack(tool: Tool, envName: String?) throws {
        if tool == .claude {
            // v3.1: claude exit capture is handled by CaptureClaudeExitCommand
            // via claude-identity.json — no binary-side sync needed.
            return
        }
        guard let (account, configDir) = try resolvePinnedAccount(tool: tool, envName: envName) else {
            return
        }
        let acctStore = AccountStore.default
        try CredentialAdapters.adapter(for: tool).syncBack(
            account: account, configDir: configDir, accountStore: acctStore)

        var refreshed = account
        if refreshed.refreshInfo(accountStore: acctStore) {
            do {
                try acctStore.save(refreshed)
            } catch {
                FileHandle.standardError.write(Data(
                    "orrery: warning: could not persist refreshed account info for '\(account.displayName)': \(error)\n".utf8
                ))
            }
        }
    }

}
