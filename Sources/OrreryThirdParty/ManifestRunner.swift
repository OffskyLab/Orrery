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

        // Task 19 adds: if lock exists → auto-uninstall.

        warnIfMissingNode()

        let cacheRoot = store.homeURL
            .appendingPathComponent("shared/thirdparty/cache")
        let (sourceDir, resolvedRef) = try fetcher.fetch(
            source: pkg.source, cacheRoot: cacheRoot,
            packageID: pkg.id, refOverride: refOverride,
            forceRefresh: forceRefresh)

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

    private func resolveClaudeDir(env: String) throws -> URL {
        _ = try store.envDir(for: env)
        return store.toolConfigDir(tool: .claude, environment: env)
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
                "warning: `node` not found on PATH. cc-statusline needs Node.js to run.\n".utf8
            ))
        }
    }
}
