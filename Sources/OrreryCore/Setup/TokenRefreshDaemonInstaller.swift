import Foundation

#if os(macOS)
import Darwin

/// Installs/self-heals the `com.offskylab.orrery.token-refresh` LaunchAgent
/// that periodically runs the dedicated `orrery-agent` executable (see
/// `Sources/orrery-agent`) even when the user never invokes `orrery`/`claude`
/// themselves — a real launchd job, not orrery's usual "piggyback on the
/// next invocation" background pattern (see `ShellFunctionGenerator`'s
/// `_check-update` hook), because token expiry doesn't wait for the user to
/// run a command.
///
/// `ProgramArguments[0]` points at a friendly-named symlink to `orrery-agent`
/// rather than the raw binary. Empirically validated on a real machine, twice
/// over: macOS's "Background Items Added" notification and the Login Items
/// & Extensions list name a launchd job after the literal filename of
/// `ProgramArguments[0]` — nothing more. A real `.app` bundle (correct
/// `Info.plist`, `lsregister -f`-registered with Launch Services, even a
/// freshly-minted LaunchAgent label to rule out stale caching) was tried and
/// made **no difference at all**: the notification still showed the raw
/// executable name and the generic "exec" icon. launchd spawns
/// `ProgramArguments[0]` directly via `posix_spawn` — it never goes through
/// `open`/Launch Services the way double-clicking an app does — so the
/// background-items UI apparently never resolves an owning bundle for it.
/// The symlink-rename trick is the only thing that has actually worked.
///
/// `ensureRegistered()` is called on every `orrery-bin` invocation from
/// `main.swift`, right alongside `AccountMigration.enforceOriginClaudeDir` —
/// the codebase's existing "ongoing invariant, self-heals every run" spot.
public enum TokenRefreshDaemonInstaller {
    static let label = "com.offskylab.orrery.token-refresh"
    static let intervalSeconds = 900 // 15 min
    static let agentExecutableName = "orrery-agent"

    static var plistURL: URL {
        userHomeURL().appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        orreryHomeURL().appendingPathComponent("logs/token-refresh.log")
    }

    /// See the type doc comment — this is what actually controls the name
    /// shown in the "Background Items Added" notification and Login Items.
    static var friendlyAgentSymlinkURL: URL {
        orreryHomeURL().appendingPathComponent("bin/Orrery Inc.")
    }

    /// Pure plist-content generator — kept separate from the installer so
    /// it's unit-testable without touching disk or launchd.
    static func plistXML(binaryPath: String, intervalSeconds: Int, logURL: URL) -> String {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath],
            "StartInterval": intervalSeconds,
            "RunAtLoad": true,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
              let xml = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return xml
    }

    /// Write the plist (if missing or stale) and (re)load it via launchctl.
    /// Best-effort: never throws, silently no-ops on any failure so a
    /// sandboxed/unusual environment can't break every `orrery` invocation.
    public static func ensureRegistered() {
        guard let agentBinaryPath = resolvedAgentBinaryPath() else { return }
        let executablePath = ensureFriendlyAgentSymlink(pointingTo: agentBinaryPath)
        let desired = plistXML(binaryPath: executablePath, intervalSeconds: intervalSeconds, logURL: logURL)
        guard !desired.isEmpty else { return }

        let existing = try? String(contentsOf: plistURL, encoding: .utf8)
        guard existing != desired else { return }

        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard (try? desired.write(to: plistURL, atomically: true, encoding: .utf8)) != nil else { return }

        let uid = getuid()
        runLaunchctl(["bootout", "gui/\(uid)/\(label)"]) // ignore failure — may not be loaded yet
        runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
    }

    /// Remove the LaunchAgent and the friendly symlink entirely (called from
    /// orrery's uninstall path).
    public static func unregister() {
        let uid = getuid()
        runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: friendlyAgentSymlinkURL)
    }

    /// Cap the agent's log file so it can't grow unbounded — called by
    /// `orrery-agent` at the start of each run, not on every `orrery`
    /// invocation.
    public static func rotateLogIfNeeded(maxBytes: Int = 1_000_000) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int,
              size > maxBytes
        else { return }
        let oldURL = logURL.appendingPathExtension("old")
        try? fm.removeItem(at: oldURL)
        try? fm.moveItem(at: logURL, to: oldURL)
    }

    /// Points `friendlyAgentSymlinkURL` at `realAgentPath`, (re)creating it
    /// if missing or stale. Falls back to returning `realAgentPath` itself
    /// if the symlink can't be created (e.g. read-only filesystem) — the
    /// daemon still installs, just under its real name.
    static func ensureFriendlyAgentSymlink(pointingTo realAgentPath: String) -> String {
        let symlinkURL = friendlyAgentSymlinkURL
        let fm = FileManager.default
        let existingTarget = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)
        guard existingTarget != realAgentPath else { return symlinkURL.path }

        try? fm.createDirectory(
            at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? fm.removeItem(at: symlinkURL)
        guard (try? fm.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: realAgentPath)) != nil else {
            return realAgentPath
        }
        return symlinkURL.path
    }

    /// `orrery-agent` ships side-by-side with `orrery-bin` (same install
    /// directory, via Homebrew/tarball/`.deb` — see `.github/workflows/release.yml`
    /// and `docs/install.sh`), so it's resolved by swapping the currently
    /// running `orrery-bin`'s filename. Returns nil if no such binary exists
    /// next to it (e.g. a dev build where only `orrery-bin` was built).
    private static func resolvedAgentBinaryPath() -> String? {
        let binaryDir = URL(fileURLWithPath: resolvedBinaryPath()).deletingLastPathComponent()
        let candidate = binaryDir.appendingPathComponent(agentExecutableName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    private static func resolvedBinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") { return arg0 }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd).appendingPathComponent(arg0).standardizedFileURL.path
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}

#endif
