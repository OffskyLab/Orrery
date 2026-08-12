import Foundation

#if os(macOS)
import Darwin

/// Installs/self-heals the `com.offskylab.orrery.token-refresh` LaunchAgent
/// that periodically runs `_refresh-tokens` (`RefreshTokensCommand`, via a
/// friendly-named symlink to the real `orrery-bin` — see
/// `friendlyBinarySymlinkURL`) even when the user never invokes
/// `orrery`/`claude` themselves — a real
/// launchd job, not orrery's usual "piggyback on the next invocation"
/// background pattern (see `ShellFunctionGenerator`'s `_check-update` hook),
/// because token expiry doesn't wait for the user to run a command.
///
/// `ensureRegistered()` is called on every `orrery-bin` invocation from
/// `main.swift`, right alongside `AccountMigration.enforceOriginClaudeDir` —
/// the codebase's existing "ongoing invariant, self-heals every run" spot.
/// It's cheap (a file read + string compare) unless the plist is missing or
/// stale (e.g. after an `orrery` binary upgrade moved the install path).
public enum TokenRefreshDaemonInstaller {
    static let label = "com.offskylab.orrery.token-refresh"
    static let intervalSeconds = 900 // 15 min

    static var plistURL: URL {
        userHomeURL().appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        orreryHomeURL().appendingPathComponent("logs/token-refresh.log")
    }

    /// macOS's "Background Items Added" notification and the Login Items list
    /// name a launchd job after the literal path passed as `ProgramArguments[0]`
    /// (not the plist's `Label`). Pointing that straight at the real
    /// `orrery-bin` executable surfaces that internal name to the user; a
    /// plainly-named symlink avoids it without renaming the distributed binary.
    static var friendlyBinarySymlinkURL: URL {
        orreryHomeURL().appendingPathComponent("bin/orrery")
    }

    /// Pure plist-content generator — kept separate from the installer so
    /// it's unit-testable without touching disk or launchd.
    static func plistXML(binaryPath: String, intervalSeconds: Int, logURL: URL) -> String {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, "_refresh-tokens"],
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
        let realBinaryPath = resolvedBinaryPath()
        let binaryPath = ensureFriendlyBinarySymlink(pointingTo: realBinaryPath)
        let desired = plistXML(binaryPath: binaryPath, intervalSeconds: intervalSeconds, logURL: logURL)
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

    /// Remove the LaunchAgent entirely (called from orrery's uninstall path).
    public static func unregister() {
        let uid = getuid()
        runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: friendlyBinarySymlinkURL)
    }

    /// Cap the daemon's log file so it can't grow unbounded — called at the
    /// start of each `_refresh-tokens` run, not on every `orrery` invocation.
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

    /// Points `friendlyBinarySymlinkURL` at `realBinaryPath`, (re)creating it
    /// if missing or stale. Falls back to returning `realBinaryPath` itself if
    /// the symlink can't be created (e.g. read-only filesystem) — the daemon
    /// still installs, just under its real name.
    static func ensureFriendlyBinarySymlink(pointingTo realBinaryPath: String) -> String {
        let symlinkURL = friendlyBinarySymlinkURL
        let fm = FileManager.default
        let existingTarget = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)
        guard existingTarget != realBinaryPath else { return symlinkURL.path }

        try? fm.createDirectory(
            at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? fm.removeItem(at: symlinkURL)
        guard (try? fm.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: realBinaryPath)) != nil else {
            return realBinaryPath
        }
        return symlinkURL.path
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
