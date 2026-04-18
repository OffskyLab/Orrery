import ArgumentParser
import Foundation

public struct CheckUpdateCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "_check-update",
        abstract: "Internal: fetch latest release and print a notice if an update is available",
        shouldDisplay: false
    )

    public init() {}

    public func run() throws {
        guard let latest = Self.fetchLatestVersion() else { return }
        let current = OrreryVersion.current
        guard latest != current else { return }
        print(L10n.Update.notice(current: current, latest: latest))

        // Dynamic notice — best-effort, always silent on failure.
        // Per spec: unparseable current version is treated as 0.0.0.
        let currentSemVer = SemanticVersion(current) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        if let extra = UpdateNoticeFetcher.production().fetch(currentVersion: currentSemVer) {
            print("")
            print(extra)
        }
    }

    private static func fetchLatestVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "curl", "-sf", "--max-time", "5",
            "-H", "Accept: application/vnd.github+json",
            "-H", "User-Agent: orrery-cli",
            "https://api.github.com/repos/OffskyLab/Orrery/releases/latest"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
