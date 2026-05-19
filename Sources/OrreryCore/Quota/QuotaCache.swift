import Foundation

/// Persists `QuotaSnapshot` per environment under `~/.orrery/quota-cache/`.
/// Each env gets its own JSON file so reads stay independent and refresh of
/// one env never invalidates another.
public struct QuotaCache: Sendable {
    private let cacheDir: URL

    public init(homeURL: URL) {
        self.cacheDir = homeURL.appendingPathComponent("quota-cache")
    }

    public func load(envName: String) -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(envName: envName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QuotaSnapshot.self, from: data)
    }

    public func save(envName: String, snapshot: QuotaSnapshot) throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(envName: envName), options: .atomic)
    }

    /// Merge a fresh per-tool quota into the env's existing snapshot. Other
    /// tool fields are preserved so refreshing claude alone doesn't clobber
    /// codex/gemini data once we add them in P3.
    public func update(envName: String, claude: UsageQuota, fetchedAt: Date = Date()) throws {
        let _ = load(envName: envName) // future: merge non-claude fields
        let merged = QuotaSnapshot(fetchedAt: fetchedAt, claude: claude)
        try save(envName: envName, snapshot: merged)
    }

    private func fileURL(envName: String) -> URL {
        // Env names come from the user; replace path separators just in case.
        let safe = envName.replacingOccurrences(of: "/", with: "_")
        return cacheDir.appendingPathComponent("\(safe).json")
    }
}
