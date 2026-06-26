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

        // For claude accounts, apply v3.1 per-account-dir layout immediately so the
        // newly-added account doesn't miss out when the global migration flag is already set.
        if refreshed.tool == .claude {
            do {
                try ClaudeAccountMigration.migrateAccount(
                    refreshed,
                    accountStore: AccountStore.default,
                    environmentStore: EnvironmentStore.default
                )

                // Capture the per-account state Claude wrote during the login session.
                // The staging dir's `.claude.json` holds `hasCompletedOnboarding`,
                // onboarding flags, and the full `oauthAccount` — without persisting it,
                // `orrery use <name>` would drop the user back into the welcome/onboarding
                // screen on first launch. The `defer` above deletes the staging dir, so we
                // must capture it here, before that fires.
                captureLoginState(stagingURL: stagingURL, account: refreshed)
            } catch {
                FileHandle.standardError.write(Data(
                    "orrery: warning: account added, but v3.1 layout setup failed: \(error). Run `orrery migrate-to-v3.1` to retry.\n".utf8
                ))
            }
        }

        // Print success line.
        let parts = [refreshed.email, refreshed.plan].compactMap { $0 }
        if parts.isEmpty {
            print(L10n.Account.addFinalized(tool.rawValue, displayName))
        } else {
            let info = parts.joined(separator: ", ")
            print(L10n.Account.addFinalizedWithInfo(tool.rawValue, displayName, info))
        }
    }

    /// Persist the per-account state Claude wrote into the staging dir's
    /// `.claude.json` (onboarding flags, theme acknowledgement, full oauthAccount)
    /// into the account's identity + the workspace's shared store. This mirrors
    /// `_capture-claude-exit`, so a freshly-added account is fully set up and
    /// `orrery use <name>` launches straight into a ready session — no welcome
    /// screen, no re-login.
    ///
    /// Best-effort: any failure here leaves the keychain-seeded identity from
    /// `migrateAccount` in place, so the account is still usable (it would just
    /// re-show onboarding). Never throws.
    private func captureLoginState(stagingURL: URL, account: Account) {
        let stagingClaudeJSON = stagingURL.appendingPathComponent(".claude.json")
        guard FileManager.default.fileExists(atPath: stagingClaudeJSON.path),
              let split = try? ClaudeJsonMerge.split(claudeJSONURL: stagingClaudeJSON)
        else { return }

        let accountDir = AccountStore.default.accountDir(id: account.id, tool: .claude)
        let identityURL = ClaudeJsonMerge.identityFileURL(accountDir: accountDir)

        // Take the login session's full per-account state (onboarding flags etc.),
        // then overlay the keychain credential `migrateAccount` already seeded so the
        // identity's `oauthAccount` is guaranteed to carry fresh tokens. Merging (rather
        // than replacing) preserves profile fields the session captured — e.g.
        // ccOnboardingFlags — that the bare keychain blob may not include.
        var identity = split.identity
        var oauth = (identity["oauthAccount"] as? [String: Any]) ?? [:]
        if let existing = ClaudeJsonMerge.loadJSON(at: identityURL),
           let keychainOauth = existing["oauthAccount"] as? [String: Any] {
            for (key, value) in keychainOauth { oauth[key] = value }
        }
        if !oauth.isEmpty { identity["oauthAccount"] = oauth }
        try? ClaudeJsonMerge.saveJSON(identity, at: identityURL)

        // Merge the shared half into the per-workspace store without clobbering state
        // contributed by other accounts pinned to the same workspace (the new login's
        // shared half overlays existing keys; existing-only keys are preserved).
        let wsDir = EnvironmentStore.default.claudeWorkspaceDir(workspace: account.workspace)
        let sharedURL = ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir)
        let existingShared = ClaudeJsonMerge.loadJSON(at: sharedURL) ?? [:]
        let mergedShared = ClaudeJsonMerge.merge(identity: split.shared, shared: existingShared)
        try? ClaudeJsonMerge.saveJSON(mergedShared, at: sharedURL)
    }
}
