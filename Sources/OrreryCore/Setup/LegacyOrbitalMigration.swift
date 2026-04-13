import Foundation

/// Interactive migration from Orbital's `~/.orbital/` directory to Orrery's `~/.orrery/`.
///
/// On every orrery invocation:
/// - If `~/.orbital/` contains envs or shared data we haven't yet asked about, prompt the user.
/// - If they say yes: move envs + shared data + top-level files, migrate Claude Keychain
///   credentials (service names contain an SHA256 of the config dir path, so they change
///   when the dir is renamed), and update shell rc files.
/// - If they say no: record declined env IDs (and shared) in
///   `~/.orrery/.migration-state.json` and don't prompt again unless new orbital data appears.
public enum LegacyOrbitalMigration {

    private struct State: Codable {
        var declinedEnvIds: [String] = []
        var declinedShared: Bool = false
    }

    private static let stateFileName = ".migration-state.json"
    private static let topLevelFiles = ["current", "sync-config.json", ".update-ts", ".update-notice"]

    public static func runIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let legacyHome = home.appendingPathComponent(".orbital")
        let newHome = home.appendingPathComponent(".orrery")

        // Heal any already-migrated env whose .claude.json was lost but has backups.
        // This runs on every invocation (cheap: existence checks per env) so envs
        // migrated by an older orrery build still recover without re-migrating.
        healExistingEnvs(newHome: newHome)

        guard dirExists(legacyHome) else { return }

        let legacyEnvsDir = legacyHome.appendingPathComponent("envs")
        let legacyEnvIds = Set(envIds(in: legacyEnvsDir))
        let newEnvIds = Set(envIds(in: newHome.appendingPathComponent("envs")))

        var state = loadState(newHome)
        let declinedIds = Set(state.declinedEnvIds)
        let candidates = legacyEnvIds.subtracting(newEnvIds).subtracting(declinedIds)

        let legacyShared = legacyHome.appendingPathComponent("shared")
        let newShared = newHome.appendingPathComponent("shared")
        let sharedPending = dirExists(legacyShared) && !dirExists(newShared) && !state.declinedShared

        guard !candidates.isEmpty || sharedPending else { return }

        // Prompt
        let err = FileHandle.standardError
        var lines: [String] = ["", "\u{1B}[1;33mOrbital → Orrery migration\u{1B}[0m"]
        if !candidates.isEmpty {
            lines.append("  \(candidates.count) 個環境還在 ~/.orbital/envs/ 裡")
        }
        if sharedPending {
            lines.append("  ~/.orbital/shared/ 有共享的 sessions/memory")
        }
        lines.append("要搬到 ~/.orrery/ 嗎？（選「不要」之後不會再詢問）")
        err.write(Data((lines.joined(separator: "\n") + "\n[Y/n] ").utf8))

        let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let accepted = input.isEmpty || input == "y" || input == "yes"

        if !accepted {
            state.declinedEnvIds.append(contentsOf: candidates)
            if sharedPending { state.declinedShared = true }
            saveState(state, newHome: newHome)
            err.write(Data("已跳過。\n".utf8))
            return
        }

        var migrated: [String] = []
        try? fm.createDirectory(at: newHome.appendingPathComponent("envs"), withIntermediateDirectories: true)

        for id in candidates {
            let src = legacyEnvsDir.appendingPathComponent(id)
            let dst = newHome.appendingPathComponent("envs").appendingPathComponent(id)
            do {
                try fm.moveItem(at: src, to: dst)
                migrated.append(id)
            } catch {
                err.write(Data("  ⚠️  env \(id) 搬移失敗：\(error.localizedDescription)\n".utf8))
            }
        }

        // Migrate Claude Keychain entries for each moved env — their service names
        // include SHA256(configDir), which changes with the renamed path.
        #if canImport(CryptoKit)
        for id in migrated {
            let oldPath = legacyEnvsDir.appendingPathComponent(id)
                .appendingPathComponent("claude").path
            let newPath = newHome.appendingPathComponent("envs").appendingPathComponent(id)
                .appendingPathComponent("claude").path
            ClaudeKeychain.copyCredential(from: oldPath, to: newPath)
        }
        #endif

        // Heal `.claude.json` loss: if a migrated env's claude dir has a `backups/`
        // directory with backup files but no `.claude.json`, restore the most recent
        // backup so Claude doesn't greet the user with "configuration file not found"
        // and refuse to continue on next launch.
        for id in migrated {
            let claudeDir = newHome.appendingPathComponent("envs").appendingPathComponent(id)
                .appendingPathComponent("claude")
            restoreClaudeJsonFromBackupIfNeeded(claudeDir: claudeDir)
        }

        if sharedPending {
            do {
                try fm.moveItem(at: legacyShared, to: newShared)
            } catch {
                err.write(Data("  ⚠️  shared/ 搬移失敗：\(error.localizedDescription)\n".utf8))
            }
        }

        for name in topLevelFiles {
            let src = legacyHome.appendingPathComponent(name)
            let dst = newHome.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }

        // Regenerate activate.sh with new ORRERY_* env var names (only if not already present).
        let activate = newHome.appendingPathComponent("activate.sh")
        if !fm.fileExists(atPath: activate.path) {
            SetupCommand.writeActivateScript(to: activate)
        }

        // Update rc files that still source the old activate.sh.
        for rcName in [".zshrc", ".bashrc", ".bash_profile", ".profile"] {
            let rc = home.appendingPathComponent(rcName)
            guard fm.fileExists(atPath: rc.path),
                  let content = try? String(contentsOf: rc, encoding: .utf8)
            else { continue }
            let updated = content
                .replacingOccurrences(of: ".orbital/activate.sh", with: ".orrery/activate.sh")
                .replacingOccurrences(of: "# orbital shell integration", with: "# orrery shell integration")
            if updated != content {
                try? updated.write(to: rc, atomically: true, encoding: .utf8)
            }
        }

        err.write(Data("已搬移 \(migrated.count) 個環境。開新 shell 或 re-source rc 檔讓新的 ORRERY_* 環境變數生效。\n".utf8))
    }

    // MARK: - Helpers

    /// Walk `~/.orrery/envs/*/claude/` and restore `.claude.json` from the latest
    /// backup for any env where it's missing but backups exist.
    private static func healExistingEnvs(newHome: URL) {
        let fm = FileManager.default
        let envsDir = newHome.appendingPathComponent("envs")
        guard let entries = try? fm.contentsOfDirectory(atPath: envsDir.path) else { return }
        for id in entries {
            let claudeDir = envsDir.appendingPathComponent(id).appendingPathComponent("claude")
            restoreClaudeJsonFromBackupIfNeeded(claudeDir: claudeDir)
        }
    }

    /// If `{claudeDir}/.claude.json` is missing but `{claudeDir}/backups/` contains
    /// one or more `.claude.json.backup.<ts>` files, copy the newest backup back
    /// into place. Claude Code's "config not found" error refuses to proceed when
    /// a backup exists — this prevents that from biting users post-migration.
    private static func restoreClaudeJsonFromBackupIfNeeded(claudeDir: URL) {
        let fm = FileManager.default
        let main = claudeDir.appendingPathComponent(".claude.json")
        guard !fm.fileExists(atPath: main.path) else { return }

        let backupsDir = claudeDir.appendingPathComponent("backups")
        guard let entries = try? fm.contentsOfDirectory(atPath: backupsDir.path) else { return }
        let backups = entries.filter { $0.hasPrefix(".claude.json.backup.") }
        guard let latest = backups.max() else { return }  // timestamp suffix sorts correctly

        let backup = backupsDir.appendingPathComponent(latest)
        try? fm.copyItem(at: backup, to: main)
    }

    private static func dirExists(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Entries in the envs dir that contain an env.json (filters out stray files / junk).
    private static func envIds(in envsDir: URL) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: envsDir.path) else { return [] }
        let entries = (try? fm.contentsOfDirectory(atPath: envsDir.path)) ?? []
        return entries.filter { entry in
            fm.fileExists(atPath: envsDir.appendingPathComponent(entry).appendingPathComponent("env.json").path)
        }
    }

    private static func loadState(_ newHome: URL) -> State {
        let url = newHome.appendingPathComponent(stateFileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private static func saveState(_ state: State, newHome: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: newHome, withIntermediateDirectories: true)
        let url = newHome.appendingPathComponent(stateFileName)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
