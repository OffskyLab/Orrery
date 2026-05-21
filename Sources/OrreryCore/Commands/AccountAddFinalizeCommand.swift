import ArgumentParser
import Foundation

/// Internal command: finalize an account-add login for Claude.
/// Invoked by the orrery shell function after `command claude` exits.
/// Reads `.orrery-prepare.json` from the staging dir to recover account info,
/// imports the credential, then cleans up the staging dir.
public struct AccountAddFinalizeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_account-add-finalize",
        abstract: "Finalize an account-add login (internal; invoked by the orrery shell function for Claude).",
        shouldDisplay: false
    )

    @Option(name: .long) public var staging: String

    public init() {}

    public func run() throws {
        let stagingURL = URL(fileURLWithPath: staging)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        // Parse the prepare metadata written by _account-add-prepare.
        let metadataURL = stagingURL.appendingPathComponent(".orrery-prepare.json")
        guard let metadataData = try? Data(contentsOf: metadataURL),
              let raw = try? JSONSerialization.jsonObject(with: metadataData) as? [String: String],
              let accountID = raw["accountID"],
              let toolRaw = raw["tool"],
              let displayName = raw["displayName"],
              let tool = Tool(rawValue: toolRaw)
        else {
            throw ValidationError("orrery: could not read prepare metadata from \(staging)/.orrery-prepare.json")
        }

        // Load the account that _account-add-prepare already saved.
        let account: Account
        do {
            account = try AccountStore.default.load(id: accountID, tool: tool)
        } catch {
            throw ValidationError("orrery: account '\(displayName)' (\(accountID)) was removed before finalize could run: \(error)")
        }

        // Import credential — roll back the account on failure.
        do {
            try AccountLoginFlow.importFrom(stagingDir: stagingURL, into: account)
        } catch {
            try? AccountStore.default.delete(id: account.id, tool: tool)
            throw error
        }

        // Reload the refreshed account (importFrom may have updated email/plan).
        let refreshed = (try? AccountStore.default.load(id: accountID, tool: tool)) ?? account

        // Print success line.
        let parts = [refreshed.email, refreshed.plan].compactMap { $0 }
        if parts.isEmpty {
            print(L10n.Account.addFinalized(tool.rawValue, displayName))
        } else {
            let info = parts.joined(separator: ", ")
            print(L10n.Account.addFinalizedWithInfo(tool.rawValue, displayName, info))
        }
    }
}
