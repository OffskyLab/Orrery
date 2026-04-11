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
        let current = Self.currentVersion()
        guard latest != current else { return }
        print(L10n.Update.notice(current: current, latest: latest))
    }

    private static func currentVersion() -> String {
        "1.1.0"
    }

    private static func fetchLatestVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "curl", "-sf", "--max-time", "5",
            "-H", "Accept: application/vnd.github+json",
            "-H", "User-Agent: orbital-cli",
            "https://api.github.com/repos/OffskyLab/Orbital/releases/latest"
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
