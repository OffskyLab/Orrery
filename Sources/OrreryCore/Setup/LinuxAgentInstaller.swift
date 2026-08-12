import Foundation

#if os(Linux)

/// Installs/self-heals a `systemd --user` service + timer that periodically
/// runs the dedicated `orrery-agent` executable (see `Sources/orrery-agent`)
/// even when the user never invokes `orrery`/`claude` themselves — the
/// Linux equivalent of `TokenRefreshDaemonInstaller`'s macOS LaunchAgent.
///
/// `ensureRegistered()` is called on every `orrery-bin` invocation from
/// `main.swift`, alongside `AccountMigration.enforceOriginClaudeDir` — the
/// codebase's existing "ongoing invariant, self-heals every run" spot.
///
/// Known limitation: `systemctl --user` requires an active session bus
/// (works for a normal desktop/SSH login; not for a fully headless/minimal
/// container without one). This deliberately does not attempt
/// `loginctl enable-linger` (needs elevated privileges) — best-effort,
/// matches the rest of this file's "never break a normal `orrery`
/// invocation" philosophy: if `systemctl --user` isn't usable, this
/// silently no-ops.
public enum LinuxAgentInstaller {
    static let unitName = "orrery-token-refresh"
    static let intervalMinutes = 15
    static let agentExecutableName = "orrery-agent"

    static var systemdUserDir: URL {
        userHomeURL().appendingPathComponent(".config/systemd/user")
    }

    static var serviceUnitURL: URL {
        systemdUserDir.appendingPathComponent("\(unitName).service")
    }

    static var timerUnitURL: URL {
        systemdUserDir.appendingPathComponent("\(unitName).timer")
    }

    /// Pure unit-content generators — kept separate from the installer so
    /// they're unit-testable without touching disk or systemd.
    static func serviceUnitContent(agentBinaryPath: String) -> String {
        """
        [Unit]
        Description=Orrery Claude account OAuth token refresh

        [Service]
        Type=oneshot
        ExecStart=\(agentBinaryPath)
        """
    }

    static func timerUnitContent(intervalMinutes: Int) -> String {
        """
        [Unit]
        Description=Run Orrery token refresh every \(intervalMinutes) minutes

        [Timer]
        OnBootSec=2min
        OnUnitActiveSec=\(intervalMinutes)min
        Persistent=true

        [Install]
        WantedBy=timers.target
        """
    }

    /// Write both unit files (if missing or stale) and (re)enable the timer
    /// via `systemctl --user`. Best-effort: never throws, silently no-ops
    /// on any failure (including no usable session bus) so a headless or
    /// unusual environment can't break every `orrery` invocation.
    public static func ensureRegistered() {
        guard let agentBinaryPath = resolvedAgentBinaryPath() else { return }

        let desiredService = serviceUnitContent(agentBinaryPath: agentBinaryPath)
        let desiredTimer = timerUnitContent(intervalMinutes: intervalMinutes)

        let existingService = try? String(contentsOf: serviceUnitURL, encoding: .utf8)
        let existingTimer = try? String(contentsOf: timerUnitURL, encoding: .utf8)
        guard existingService != desiredService || existingTimer != desiredTimer else { return }

        try? FileManager.default.createDirectory(at: systemdUserDir, withIntermediateDirectories: true)
        guard (try? desiredService.write(to: serviceUnitURL, atomically: true, encoding: .utf8)) != nil,
              (try? desiredTimer.write(to: timerUnitURL, atomically: true, encoding: .utf8)) != nil
        else { return }

        runSystemctl(["--user", "daemon-reload"])
        runSystemctl(["--user", "enable", "--now", "\(unitName).timer"])
    }

    /// Remove the systemd unit files entirely (called from orrery's
    /// uninstall path).
    public static func unregister() {
        runSystemctl(["--user", "disable", "--now", "\(unitName).timer"])
        try? FileManager.default.removeItem(at: serviceUnitURL)
        try? FileManager.default.removeItem(at: timerUnitURL)
        runSystemctl(["--user", "daemon-reload"])
    }

    /// `orrery-agent` ships side-by-side with `orrery-bin` (same install
    /// directory — see `.github/workflows/release.yml` and
    /// `docs/install.sh`), so it's resolved by swapping the currently
    /// running `orrery-bin`'s filename. Returns nil if no such binary
    /// exists next to it (e.g. a dev build where only `orrery-bin` was
    /// built).
    private static func resolvedAgentBinaryPath() -> String? {
        let arg0 = CommandLine.arguments[0]
        let binaryPath = arg0.hasPrefix("/")
            ? arg0
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(arg0).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: binaryPath)
            .deletingLastPathComponent()
            .appendingPathComponent(agentExecutableName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    @discardableResult
    private static func runSystemctl(_ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["systemctl"] + args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}

#endif
