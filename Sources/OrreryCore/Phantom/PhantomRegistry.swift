import Foundation

/// Read/write access to the phantom supervisor registry.
///
/// Layout — one directory per live supervisor:
///
///     <home>/phantom/<supervisor-pid>/meta.json
///     <home>/phantom/<supervisor-pid>/sentinel
///
/// The sentinel is per-entry on purpose. It used to be a single global
/// `<home>/.phantom-sentinel`, which meant two concurrent claude sessions
/// would read each other's switch requests and resume into the wrong
/// conversation.
///
/// There is no separate GC pass: `liveEntries` prunes dead entries as a side
/// effect of every read, which is the only time staleness can matter.
public struct PhantomRegistry: Sendable {
    public let rootURL: URL

    public init(homeURL: URL) {
        self.rootURL = homeURL.appendingPathComponent("phantom")
    }

    public func entryDirURL(id: String) -> URL {
        rootURL.appendingPathComponent(id)
    }

    public func metaURL(id: String) -> URL {
        entryDirURL(id: id).appendingPathComponent("meta.json")
    }

    public func sentinelURL(id: String) -> URL {
        entryDirURL(id: id).appendingPathComponent("sentinel")
    }

    public func write(_ entry: PhantomEntry, id: String) throws {
        try FileManager.default.createDirectory(
            at: entryDirURL(id: id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(entry).write(to: metaURL(id: id), options: .atomic)
    }

    public func read(id: String) -> PhantomEntry? {
        guard let data = try? Data(contentsOf: metaURL(id: id)) else { return nil }
        return try? JSONDecoder().decode(PhantomEntry.self, from: data)
    }

    public func remove(id: String) {
        try? FileManager.default.removeItem(at: entryDirURL(id: id))
    }

    /// Every live entry, pruning any that are dead or unreadable.
    ///
    /// `isAlive` is injected rather than called directly so the pid-recycling
    /// logic is testable without spawning real processes.
    public func liveEntries(
        isAlive: (Int32, Double) -> Bool
    ) -> [(id: String, entry: PhantomEntry)] {
        guard let ids = try? FileManager.default.contentsOfDirectory(
            atPath: rootURL.path) else { return [] }

        var result: [(id: String, entry: PhantomEntry)] = []
        for id in ids.sorted() {
            guard let entry = read(id: id) else {
                // Unreadable or corrupt — nothing can use it, so drop it.
                remove(id: id)
                continue
            }
            if isAlive(entry.supervisorPid, entry.supervisorStartedAt) {
                result.append((id: id, entry: entry))
            } else {
                remove(id: id)
            }
        }
        return result
    }
}
