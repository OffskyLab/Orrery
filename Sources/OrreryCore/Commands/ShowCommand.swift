import ArgumentParser
import Foundation

public struct ShowCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: L10n.Account.showAbstract
    )

    public init() {}

    public func run() throws {
        let envStore = EnvironmentStore.default
        let acctStore = AccountStore.default

        let activeEnvName: String
        let pins: [String: AccountID]
        let activeEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        if let activeEnv, activeEnv != Workspace.reservedOriginName {
            activeEnvName = activeEnv
            var resolved: [String: AccountID] = [:]
            do {
                resolved = try envStore.load(named: activeEnvName).accounts
            } catch {
                FileHandle.standardError.write(Data(
                    "orrery: warning: could not load env '\(activeEnvName)': \(error)\n".utf8))
            }
            pins = resolved
        } else {
            activeEnvName = Workspace.reservedOriginName
            pins = envStore.loadOriginWorkspace().accounts
        }

        print(L10n.Account.showActiveEnv(activeEnvName))
        for tool in Tool.allCases {
            // `orrery use` for claude/codex, once an account is on the v3.1
            // account-dir layout, only exports CLAUDE_CONFIG_DIR/CODEX_HOME into
            // the current shell session via the `_account-dir` fast path — it
            // never updates the persisted pin (see UseCommand). So the persisted
            // pin can silently disagree with what this shell will actually use.
            // Surface that instead of just the (possibly stale) persisted pin.
            if let manager = AccountDirectoryRuntime.manager(ifAvailable: tool),
               let live = Self.liveAccount(tool: tool, manager: manager, acctStore: acctStore),
               live.id != pins[tool.rawValue] {
                print("  \(tool.rawValue): \(live.displayName)\(Self.infoSuffix(live)) [this shell only — via `orrery use`; default is \(Self.defaultLabel(tool: tool, pins: pins, acctStore: acctStore))]")
                continue
            }

            if let id = pins[tool.rawValue],
               let acct = try? acctStore.load(id: id, tool: tool) {
                print(L10n.Account.showRowPinned(tool.rawValue, acct.displayName, Self.infoSuffix(acct)))
            } else {
                print(L10n.Account.showRowUnpinned(tool.rawValue))
            }
        }
    }

    private static func infoSuffix(_ acct: Account) -> String {
        let joined = [acct.email, acct.plan].compactMap { $0 }.joined(separator: ", ")
        return joined.isEmpty ? "" : " (\(joined))"
    }

    private static func defaultLabel(tool: Tool, pins: [String: AccountID], acctStore: AccountStore) -> String {
        guard let id = pins[tool.rawValue], let acct = try? acctStore.load(id: id, tool: tool) else {
            return "unpinned"
        }
        return acct.displayName
    }

    /// Resolves the account actually in effect for *this shell*, from the
    /// tool's account-dir env var (set by `orrery use` — see
    /// `AccountDirLookupCommand`, which exports whatever `manager.resolvedExportPath`
    /// produces — the account dir itself for claude/codex, a HOME-wrapper dir
    /// for gemini). Returns nil if unset, or set to something that isn't a
    /// known pool account — callers fall back to the persisted pin in that case.
    private static func liveAccount(tool: Tool, manager: ToolAccountManaging, acctStore: AccountStore) -> Account? {
        guard let configDir = ProcessInfo.processInfo.environment[manager.exportEnvVarName],
              !configDir.isEmpty
        else { return nil }
        let id = manager.accountID(fromExportPath: URL(fileURLWithPath: configDir))
        return try? acctStore.load(id: id, tool: tool)
    }
}
