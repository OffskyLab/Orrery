import Foundation

/// Claude Code's login state lives in two places:
/// - Credential store: macOS Keychain entry (service name derived from CLAUDE_CONFIG_DIR
///   hash), or on Linux `{configDir}/.credentials.json`.
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
        let fm = FileManager.default
        let isOrigin = sourceDir == nil

        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Credential store: origin has no hash suffix (Keychain) / lives at
        // ~/.claude/.credentials.json (Linux); envs use the config-dir-derived store.
        let srcCredDir: String? = isOrigin ? nil : sourceDir?.path
        let credOK = ClaudeKeychain.copyCredential(from: srcCredDir, to: targetDir.path)

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
        return credOK && jsonOK
    }

    public static func copyNonLoginSettings(sourceDir: URL, targetDir: URL) {
        // backups/ — identity snapshots (.claude.json.backup.*); copying them would let
        //   the heal step restore the source's identity into the target, defeating prepareForSelfLogin.
        // session dirs — project/session/session-env data is machine- and account-specific.
        // cache/ stats-cache.json statsig/ — per-account caches; Claude Code repopulates them.
        // agent-memory/ — accumulated agent memory belonging to the source account.
        // telemetry/ usage-data/ — analytics, never meaningful to carry over.
        // mcp-needs-auth-cache.json — account-specific MCP auth state.
        // paste-cache/ shell-snapshots/ history.jsonl file-history/ debug/ downloads/ — ephemeral.
        // plans/ tasks/ todos/ — in-progress work state from the source session.
        var skip: Set<String> = [
            "backups",
            "cache",
            "stats-cache.json",
            "statsig",
            "agent-memory",
            "telemetry",
            "usage-data",
            "mcp-needs-auth-cache.json",
            "paste-cache",
            "shell-snapshots",
            "history.jsonl",
            "file-history",
            "debug",
            "downloads",
            "plans",
            "tasks",
            "todos",
        ]
        skip.formUnion(Tool.claude.sessionSubdirectories)
        copyDirectoryContents(from: sourceDir, to: targetDir, skipping: skip)
    }

    /// Called when the user chose "I'll log in myself". Strips foreign identity keys
    /// and onboarding markers from `.claude.json` so Claude runs its own onboarding
    /// + login flow at next launch, instead of silently adopting the clone source's
    /// identity or skipping login entirely. No-op if `.claude.json` doesn't exist
    /// (in which case Claude will run the full flow naturally).
    public static func prepareForSelfLogin(targetDir: URL) {
        let url = targetDir.appendingPathComponent(".claude.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        for key in identityKeys {
            obj.removeValue(forKey: key)
        }
        for key in ephemeralKeys {
            obj.removeValue(forKey: key)
        }

        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? out.write(to: url, options: .atomic)
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
