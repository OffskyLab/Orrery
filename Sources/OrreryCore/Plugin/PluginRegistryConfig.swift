import Foundation

/// What orrery installed, written down.
///
/// This is the answer to "which tools exist". It replaces `Tool.allCases`, and
/// it has to exist before that enum can go: `PluginDiscovery.locate(toolID:)` is
/// a lookup by id, so something must supply the ids, and the enum is the only
/// thing that does today.
///
/// ## Not a scan
///
/// orrery does not look in `$ORRERY_HOME/tools` or on `PATH` to see what might
/// be there. Discovery is a recorded fact: orrery installs a plugin, runs its
/// registration, and writes the result here. A scan would pay for discovery on
/// every invocation and — the real objection — would make "what is installed" an
/// inference from the filesystem rather than something orrery decided.
///
/// A binary sitting in the tools directory that was never registered is not a
/// plugin. It is a file.
///
/// ## Capabilities, not presence
///
/// `initialize` advertises per method, so what is recorded is not "claude is
/// installed" but "claude is installed and can do these things". That answers
/// what a plugin must implement to be manageable at all: nothing in particular.
/// It implements what it can, the rest is recorded as unavailable, and orrery
/// says so when asked to do one of them.
public struct PluginRegistryConfig: Sendable {

    /// One registered plugin.
    public struct Entry: Sendable, Equatable, Codable {
        public let id: String
        public let binaryPath: URL
        public let capabilities: Set<String>
        public let registeredAt: Date

        /// Whether the binary is still where registration put it.
        ///
        /// Computed on read by stat-ing the path — one syscall, no spawn — and
        /// deliberately not stored: a stored flag would be a second copy of a
        /// fact the filesystem already holds, and would go stale the moment
        /// anything touched the file.
        ///
        /// **Accepted limitation:** a stat catches removal, not substitution. A
        /// plugin upgraded in place to a build with a different capability set
        /// is still described by the recorded registration. Re-registering every
        /// run would catch it, at one spawn per run, and buys little while
        /// plugins negotiate a protocol version at `initialize`.
        public var isAvailable: Bool {
            FileManager.default.isExecutableFile(atPath: binaryPath.path)
        }

        public func can(_ method: String) -> Bool {
            capabilities.contains(method)
        }
    }

    public let homeURL: URL

    public init(homeURL: URL) {
        self.homeURL = homeURL
    }

    public static var `default`: PluginRegistryConfig {
        PluginRegistryConfig(homeURL: orreryHomeURL())
    }

    public var fileURL: URL {
        homeURL.appendingPathComponent("plugins.json")
    }

    /// Every plugin orrery has registered, whether or not its binary is still
    /// there.
    ///
    /// - Throws: when the file exists but cannot be understood. An unreadable
    ///   config is not an empty one: treating it as empty would silently drop
    ///   every installed tool and present a fresh-install experience to someone
    ///   whose install is merely damaged.
    public func entries() throws -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try JSONDecoder.registry.decode([Entry].self, from: data)
    }

    /// Record a plugin, replacing any earlier registration of the same id.
    ///
    /// Replacing rather than appending because an id identifies a tool, not an
    /// installation: a reinstall to a new path is the same tool, and two entries
    /// for it would leave which one wins to ordering.
    public func register(id: String, binaryPath: URL, capabilities: Set<String>) throws {
        var all = try entries().filter { $0.id != id }
        all.append(Entry(id: id, binaryPath: binaryPath,
                         capabilities: capabilities, registeredAt: Date()))
        try write(all)
    }

    /// Forget a plugin deliberately.
    ///
    /// Distinct from a binary that vanished, which stays recorded and is marked
    /// unavailable. This is uninstall; that is breakage.
    public func unregister(id: String) throws {
        try write(try entries().filter { $0.id != id })
    }

    private func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(
            at: homeURL, withIntermediateDirectories: true)
        try JSONEncoder.registry.encode(entries).write(to: fileURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static var registry: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var registry: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
