import Foundation

/// One-time migration from Orbital's config dir to Orrery's on first run.
///
/// Detects an existing `~/.orbital/` with no `~/.orrery/` alongside it, moves the
/// directory, regenerates `activate.sh` with the new `ORRERY_*` env var names,
/// and updates shell rc files to source the new location.
public enum LegacyOrbitalMigration {

    /// Run the migration if needed. Safe to call multiple times — it no-ops when
    /// there's no legacy `~/.orbital/` to migrate.
    @discardableResult
    public static func runIfNeeded() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let legacy = home.appendingPathComponent(".orbital")
        let current = home.appendingPathComponent(".orrery")

        var isDir: ObjCBool = false
        let legacyExists = fm.fileExists(atPath: legacy.path, isDirectory: &isDir) && isDir.boolValue
        let currentExists = fm.fileExists(atPath: current.path)

        // Nothing to do if the legacy dir is absent, or if the user already has an
        // `~/.orrery/` (we don't want to clobber their new state with old data).
        guard legacyExists, !currentExists else { return false }

        let err = FileHandle.standardError
        err.write(Data("\u{1B}[1;33mOrbital was renamed to Orrery. Migrating ~/.orbital/ → ~/.orrery/ (one-time)…\u{1B}[0m\n".utf8))

        do {
            try fm.moveItem(at: legacy, to: current)
        } catch {
            err.write(Data("  migration failed: \(error.localizedDescription)\n".utf8))
            return false
        }
        err.write(Data("  moved config dir\n".utf8))

        // Regenerate activate.sh with the new ORRERY_* env var names and shell function.
        let activate = current.appendingPathComponent("activate.sh")
        SetupCommand.writeActivateScript(to: activate)

        // Update rc files that source the old `.orbital/activate.sh` path.
        let rcNames = [".zshrc", ".bashrc", ".bash_profile", ".profile"]
        for rcName in rcNames {
            let rc = home.appendingPathComponent(rcName)
            guard fm.fileExists(atPath: rc.path),
                  let content = try? String(contentsOf: rc, encoding: .utf8)
            else { continue }
            let updated = content
                .replacingOccurrences(of: ".orbital/activate.sh", with: ".orrery/activate.sh")
                .replacingOccurrences(of: "# orbital shell integration", with: "# orrery shell integration")
            if updated != content {
                try? updated.write(to: rc, atomically: true, encoding: .utf8)
                err.write(Data("  updated \(rcName)\n".utf8))
            }
        }

        err.write(Data("Migration complete. Open a new shell (or re-source your rc file) to pick up the new ORRERY_* env vars.\n".utf8))
        return true
    }
}
