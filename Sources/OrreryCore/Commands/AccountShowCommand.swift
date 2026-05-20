import ArgumentParser
import Foundation

public struct AccountShowCommand: ParsableCommand {
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
        if let activeEnv, activeEnv != ReservedEnvironment.defaultName {
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
            activeEnvName = ReservedEnvironment.defaultName
            pins = envStore.loadOriginConfig().accounts
        }

        print(L10n.Account.showActiveEnv(activeEnvName))
        for tool in Tool.allCases {
            if let id = pins[tool.rawValue],
               let acct = try? acctStore.load(id: id, tool: tool) {
                print(L10n.Account.showRowPinned(tool.rawValue, acct.displayName))
            } else {
                print(L10n.Account.showRowUnpinned(tool.rawValue))
            }
        }
    }
}
