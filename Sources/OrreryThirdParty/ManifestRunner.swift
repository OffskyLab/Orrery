import Foundation
import OrreryCore

public struct ManifestRunner: ThirdPartyRunner {
    private let store: EnvironmentStore
    private let fetcher: ThirdPartySourceFetcher

    public init(store: EnvironmentStore = .default,
                fetcher: ThirdPartySourceFetcher = GitSource()) {
        self.store = store
        self.fetcher = fetcher
    }

    public func install(_ pkg: ThirdPartyPackage,
                        into env: String,
                        refOverride: String?,
                        forceRefresh: Bool) throws -> InstallRecord {
        let claudeDir = try resolveClaudeDir(env: env)
        let lockURL = lockFileURL(claudeDir: claudeDir, packageID: pkg.id)

        // Already installed? Reinstall = uninstall + install (spec decision 7c-B).
        if FileManager.default.fileExists(atPath: lockURL.path) {
            FileHandle.standardError.write(Data(
                "\(pkg.id) already installed — reinstalling.\n".utf8))
            try uninstall(packageID: pkg.id, from: env)
        }

        warnIfMissingNode()

        let cacheRoot = store.homeURL
            .appendingPathComponent("shared/thirdparty/cache")
        let fetched = try fetcher.fetch(
            source: pkg.source, cacheRoot: cacheRoot,
            packageID: pkg.id, refOverride: refOverride,
            forceRefresh: forceRefresh)
        let sourceDir = fetched.dir
        let resolvedRef = fetched.sha

        var copied: [String] = []
        var patched: [SettingsPatchRecord] = []

        do {
            for step in pkg.steps {
                switch step {
                case .copyFile:
                    copied.append(contentsOf: try CopyFileExecutor.apply(
                        step, sourceDir: sourceDir, claudeDir: claudeDir))
                case .copyGlob:
                    copied.append(contentsOf: try CopyGlobExecutor.apply(
                        step, sourceDir: sourceDir, claudeDir: claudeDir))
                case .patchSettings:
                    let rec = try PatchSettingsExecutor.apply(
                        step, claudeDir: claudeDir,
                        placeholders: ["<CLAUDE_DIR>": claudeDir.path])
                    patched.append(rec)
                }
            }
        } catch {
            for rec in patched.reversed() {
                try? PatchSettingsExecutor.rollback(record: rec, claudeDir: claudeDir)
            }
            CopyFileExecutor.rollback(paths: copied, claudeDir: claudeDir)
            throw error
        }

        let manifestRef: String
        if case .git(_, let ref) = pkg.source { manifestRef = ref }
        else if case .vendored = pkg.source { manifestRef = "vendored" }
        else { manifestRef = "" }

        let record = InstallRecord(
            packageID: pkg.id,
            resolvedRef: resolvedRef,
            manifestRef: refOverride ?? manifestRef,
            displayRef: fetched.displayLabel,
            installedAt: Date(),
            copiedFiles: copied,
            patchedSettings: patched
        )
        try writeLock(record, to: lockURL)
        return record
    }

    public func uninstall(packageID: String, from env: String) throws {
        let claudeDir = try resolveClaudeDir(env: env)
        let lockURL = lockFileURL(claudeDir: claudeDir, packageID: packageID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: lockURL.path) else {
            throw ThirdPartyError.notInstalled(id: packageID)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(InstallRecord.self,
                                        from: Data(contentsOf: lockURL))

        for patchRec in record.patchedSettings.reversed() {
            try? PatchSettingsExecutor.rollback(record: patchRec, claudeDir: claudeDir)
        }
        for p in record.copiedFiles {
            try? fm.removeItem(at: claudeDir.appendingPathComponent(p))
        }
        // Prune any empty directories left by copyGlob steps.
        let parentDirs = Set(record.copiedFiles.map { path -> String in
            guard let slash = path.lastIndex(of: "/") else { return "" }
            return String(path[..<slash])
        }).filter { !$0.isEmpty && $0 != "." }
        for rel in parentDirs.sorted(by: { $0.count > $1.count }) {
            let dir = claudeDir.appendingPathComponent(rel)
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path),
               contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
        try? fm.removeItem(at: lockURL)
        let thirdDir = claudeDir.appendingPathComponent(".thirdparty")
        if let contents = try? fm.contentsOfDirectory(atPath: thirdDir.path),
           contents.isEmpty {
            try? fm.removeItem(at: thirdDir)
        }
    }

    public func listInstalled(in env: String) throws -> [InstallRecord] {
        let claudeDir = try resolveClaudeDir(env: env)
        let thirdDir = claudeDir.appendingPathComponent(".thirdparty")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: thirdDir.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries.compactMap { name in
            guard name.hasSuffix(".lock.json") else { return nil }
            let url = thirdDir.appendingPathComponent(name)
            return try? decoder.decode(InstallRecord.self,
                                       from: Data(contentsOf: url))
        }
    }

    // MARK: - Helpers

    /// Resolve the install target. In v3.1 the target is the *account* dir —
    /// the `CLAUDE_CONFIG_DIR` Claude actually reads — never the shared workspace.
    /// An account chooses which workspace it links to (default origin), not the
    /// other way around, so third-party files (the settings.json patch and the
    /// statusline script) must land in the account dir to take effect: there
    /// `settings.json` and the script are real files, not symlinks back to the
    /// workspace, so installing into the workspace would be invisible to Claude.
    private func resolveClaudeDir(env: String) throws -> URL {
        let fm = FileManager.default

        // Preferred: the live active account dir exported by `orrery use`.
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configDir.isEmpty {
            let dir = URL(fileURLWithPath: configDir)
            if fm.fileExists(atPath: dir.appendingPathComponent("metadata.json").path) {
                return dir
            }
        }

        // Fallback (no active claude account selected, e.g. plain origin):
        // resolve the claude account pinned to `env` and use its account dir.
        let pins: [String: AccountID]
        if env == Workspace.reservedOriginName {
            pins = store.loadOriginWorkspace().accounts
        } else {
            do { pins = try store.load(named: env).accounts }
            catch { throw ThirdPartyError.envNotFound(env) }
        }
        guard let accountID = pins[Tool.claude.rawValue] else {
            throw ThirdPartyError.envNotFound(env)
        }
        // Use the same home as the injected EnvironmentStore (keeps tests and
        // custom ORRERY_HOME installs consistent — never the process default).
        return AccountStore(homeURL: store.homeURL).accountDir(id: accountID, tool: .claude)
    }

    private func lockFileURL(claudeDir: URL, packageID: String) -> URL {
        claudeDir.appendingPathComponent(".thirdparty/\(packageID).lock.json")
    }

    private func writeLock(_ record: InstallRecord, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    private func warnIfMissingNode() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["node"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            FileHandle.standardError.write(Data(
                "warning: `node` not found on PATH. statusline needs Node.js to run.\n".utf8
            ))
        }
    }
}
