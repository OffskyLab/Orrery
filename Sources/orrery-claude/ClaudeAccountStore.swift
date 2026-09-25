import Foundation
import AIToolKit

/// Claude's accounts, stored by the plugin that owns them.
///
/// The layout is this file's business and nothing else's. orrery hands over a
/// root and never looks inside it — which is the point: a host that knew the
/// layout would be back to owning the pool and asking the plugin to look things
/// up in it.
///
/// ## The layout
///
/// One directory per account, named by its id, holding `metadata.json`. Inherited
/// from what orrery used, because a layout that changes for no reason is a
/// migration nobody asked for. The difference is who may know about it.
///
/// ## Which failures are fatal
///
/// An account whose `metadata.json` cannot be read is **skipped with a warning**,
/// not thrown. A listing is worth producing with one row missing; refusing to
/// list anything because one directory is damaged would take away the command a
/// person needs in order to notice and delete it.
///
/// Warnings go to stderr. stdout carries the protocol, and a stray write there
/// desynchronises the stream.
struct ClaudeAccountStore {

    /// Where the host said this plugin may write.
    let root: URL

    enum Failure: Error, CustomStringConvertible {
        /// The host spawned the plugin without telling it where it may write.
        /// Distinct from an empty pool: there is nowhere to even look.
        case noStateDirectory

        var description: String {
            switch self {
            case .noStateDirectory:
                return "the host did not supply \(PluginState.directoryEnvVar), "
                    + "so this plugin has nowhere to store accounts"
            }
        }
    }

    init(root: URL) {
        self.root = root
    }

    /// - Throws: ``Failure/noStateDirectory`` when the host supplied no root.
    ///   Deliberately not a fallback to a derived home: the plugin would then
    ///   read the developer's real config during an isolated run.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let directory = PluginState.directory(environment: environment) else {
            throw Failure.noStateDirectory
        }
        self.root = directory
    }

    // MARK: - Layout

    private var accountsDir: URL { root.appendingPathComponent("accounts") }

    private func accountDir(_ id: AccountID) -> URL {
        accountsDir.appendingPathComponent(id)
    }

    private func metadataURL(_ id: AccountID) -> URL {
        accountDir(id).appendingPathComponent("metadata.json")
    }

    /// The config directory claude itself reads for this account.
    ///
    /// Named `.claude` because that is what claude looks for, and this is the
    /// process allowed to know that. It sits inside the account's own directory
    /// so that deleting the account takes its config with it.
    func configDir(for id: AccountID) -> URL {
        accountDir(id).appendingPathComponent(".claude")
    }

    /// Create the config directory for an account that has just been added.
    ///
    /// Separate from ``add(id:name:)`` only so the reason is visible: an account
    /// without a config directory is recorded but not usable, and claude creates
    /// nothing until it is first run.
    func prepareConfigDir(for id: AccountID) throws {
        try FileManager.default.createDirectory(
            at: configDir(for: id), withIntermediateDirectories: true)
    }

    private var currentURL: URL { root.appendingPathComponent("current") }

    // MARK: - Reading

    func list() throws -> [Account] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: accountsDir.path) else { return [] }

        let ids = try fm.contentsOfDirectory(atPath: accountsDir.path)
            .filter { !$0.hasPrefix(".") }

        return ids.compactMap { id in
            do {
                return try load(id: id)
            } catch {
                FileHandle.standardError.write(Data(
                    "orrery-claude: skipping unreadable account '\(id)': \(error)\n".utf8))
                return nil
            }
        }
        .sorted { $0.name < $1.name }
    }

    func load(id: AccountID) throws -> Account {
        let url = metadataURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AccountError.noSuchAccount(id)
        }
        return try decoder.decode(Account.self, from: try Data(contentsOf: url))
    }

    func current() throws -> Account? {
        guard let data = try? Data(contentsOf: currentURL),
              let id = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return nil }

        // A pin to something that no longer exists reads as nothing pinned
        // rather than as an error. The account it named is gone; saying so as a
        // failure would make every caller handle a state it cannot fix.
        return try? load(id: id)
    }

    // MARK: - Writing

    func add(id: AccountID, name: String) throws -> Account {
        guard !exists(id) else { throw AccountError.alreadyExists(id) }

        let account = Account(id: id, name: name)
        try FileManager.default.createDirectory(
            at: accountDir(id), withIntermediateDirectories: true)
        try encoder.encode(account).write(to: metadataURL(id), options: .atomic)
        return account
    }

    func setCurrent(id: AccountID) throws {
        guard exists(id) else { throw AccountError.noSuchAccount(id) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        try Data(id.utf8).write(to: currentURL, options: .atomic)
    }

    func delete(id: AccountID) throws {
        guard exists(id) else { throw AccountError.noSuchAccount(id) }
        try FileManager.default.removeItem(at: accountDir(id))

        // Clearing the pin is not optional. Leaving `current` naming a deleted
        // account would have the host render a row for something gone.
        if let pinned = try? Data(contentsOf: currentURL),
           String(data: pinned, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines) == id {
            try? FileManager.default.removeItem(at: currentURL)
        }
    }

    private func exists(_ id: AccountID) -> Bool {
        FileManager.default.fileExists(atPath: metadataURL(id).path)
    }

    // MARK: - Coding

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder { JSONDecoder() }
}
