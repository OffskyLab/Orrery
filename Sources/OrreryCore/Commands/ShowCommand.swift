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
            // `orrery use` for claude only exports CLAUDE_CONFIG_DIR into the
            // current shell session — it never updates the persisted pin (see
            // UseCommand). So the persisted pin can silently disagree with what
            // this shell will actually use. Surface that instead of just the
            // (possibly stale) persisted pin.
            if tool == .claude, let live = Self.liveClaudeAccount(acctStore: acctStore),
               live.id != pins[tool.rawValue] {
                print("  claude: \(live.displayName)\(Self.infoSuffix(live)) [this shell only — via `orrery use`; default is \(Self.defaultLabel(tool: tool, pins: pins, acctStore: acctStore))]")
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

    /// Resolves the Claude account actually in effect for *this shell*, from
    /// `CLAUDE_CONFIG_DIR` (set by `orrery use` — see `AccountDirLookupCommand`,
    /// which always points it at `~/.orrery/accounts/claude/<id>`). Returns nil
    /// if unset, or set to something that isn't a known pool account (e.g. unset,
    /// or pointing outside the pool layout) — callers fall back to the persisted
    /// pin in that case.
    private static func liveClaudeAccount(acctStore: AccountStore) -> Account? {
        guard let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
              !configDir.isEmpty
        else { return nil }
        let id = URL(fileURLWithPath: configDir).lastPathComponent
        return try? acctStore.load(id: id, tool: .claude)
    }
}
