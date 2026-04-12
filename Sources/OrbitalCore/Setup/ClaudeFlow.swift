import Foundation

/// Claude Code's login state lives in two places:
/// - macOS Keychain entry (service name derived from CLAUDE_CONFIG_DIR hash)
/// - `.claude.json` (at `$HOME/.claude.json` for origin, `{CLAUDE_CONFIG_DIR}/.claude.json` for env)
///
/// Extra nuance: `.claude.json` mixes identity (oauthAccount, userID, onboarding flags)
/// with user preferences (theme, dismissed dialogs, projects, usage counters). When the
/// user picks "login from B" + "settings from A", we merge: keep A as the base for prefs,
/// overlay only the identity keys from B. This requires clone to run BEFORE login copy.
public enum ClaudeFlow: ToolFlow {
    public static var supportsMemoryIsolation: Bool { true }

    /// Keys that represent "who the user is" — these follow the login source.
    /// Everything else in `.claude.json` follows the clone source (preferences like theme,
    /// dismissed dialogs, projects, usage counters).
    private static let identityKeys: Set<String> = [
        "oauthAccount",
        "userID",
        "anonymousId",
        "hasCompletedOnboarding",
        "lastOnboardingVersion",
    ]

    /// Per-account caches that shouldn't carry over from the clone source (their values
    /// belong to the clone source's account, not the target's). Stripped during merge;
    /// Claude Code repopulates them on next launch.
    private static let ephemeralKeys: Set<String> = [
        "cachedGrowthBookFeatures",
        "cachedStatsigGates",
    ]

    public static func copyLoginState(sourceDir: URL?, targetDir: URL) -> Bool {
        #if canImport(CryptoKit)
        let fm = FileManager.default
        let isOrigin = sourceDir == nil

        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Keychain: origin has no hash suffix; envs use SHA256(configDir) hash.
        let srcKeychainDir: String? = isOrigin ? nil : sourceDir?.path
        let keychainOK = ClaudeKeychain.copyCredential(from: srcKeychainDir, to: targetDir.path)

        // .claude.json — location differs between origin and env configs.
        let srcJson: URL = isOrigin
            ? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
            : sourceDir!.appendingPathComponent(".claude.json")
        let dstJson = targetDir.appendingPathComponent(".claude.json")

        var jsonOK = true
        if fm.fileExists(atPath: srcJson.path) {
            if fm.fileExists(atPath: dstJson.path) {
                // Clone-source .claude.json already in place — merge identity from login source.
                jsonOK = mergeIdentityKeys(from: srcJson, into: dstJson)
            } else {
                jsonOK = copySingleFile(from: srcJson, to: dstJson)
            }
        }
        return keychainOK && jsonOK
        #else
        return false
        #endif
    }

    public static func copyNonLoginSettings(sourceDir: URL, targetDir: URL) {
        // Keep `.claude.json` — the login step will merge identity into it after this runs.
        var skip: Set<String> = []
        skip.formUnion(Tool.claude.sessionSubdirectories)
        copyDirectoryContents(from: sourceDir, to: targetDir, skipping: skip)
    }

    /// Overlay identity keys from `sourceLogin` onto an existing `targetExisting` .claude.json.
    /// Preserves everything else (theme, projects, usage, caches…). Writes back pretty-printed.
    private static func mergeIdentityKeys(from sourceLogin: URL, into targetExisting: URL) -> Bool {
        guard let sourceData = try? Data(contentsOf: sourceLogin),
              let targetData = try? Data(contentsOf: targetExisting),
              let source = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              var target = try? JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        else { return false }

        // Overlay identity keys from source; if source doesn't have a key, KEEP target's
        // existing value (don't delete). This matters when the login source has a partial
        // .claude.json — e.g., missing `hasCompletedOnboarding` — we shouldn't strip that
        // from the clone-source-provided base.
        for key in identityKeys {
            if let v = source[key] {
                target[key] = v
            }
        }
        // Drop per-account caches so Claude Code repopulates them for the target account.
        for key in ephemeralKeys {
            target.removeValue(forKey: key)
        }

        guard let merged = try? JSONSerialization.data(withJSONObject: target, options: [.prettyPrinted]) else {
            return false
        }
        do { try merged.write(to: targetExisting); return true } catch { return false }
    }
}
