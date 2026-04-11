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
        "1.0.7"
    }

    private static func fetchLatestVersion() -> String? {
        guard let url = URL(string: "https://api.github.com/repos/OffskyLab/Orbital/releases/latest") else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("orbital-cli", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            result = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        }.resume()

        semaphore.wait()
        return result
    }
}
