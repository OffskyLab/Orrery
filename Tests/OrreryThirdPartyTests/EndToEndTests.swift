import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("End-to-end — vendored source")
struct EndToEndTests {
    @Test("full install then uninstall leaves env byte-equivalent (empty)")
    func fullRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: home)
        try store.save(OrreryEnvironment(name: "dev"))
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "dev")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let before = snapshot(at: claudeDir)

        let src = home.appendingPathComponent("src")
        let hooks = src.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Data("statusline".utf8).write(to: src.appendingPathComponent("statusline.js"))
        for name in ["message-tracker.js", "summary-updater.js", "file-tracker.js"] {
            try Data(name.utf8).write(to: hooks.appendingPathComponent(name))
        }

        var pkg = try BuiltInRegistry().lookup("statusline")
        pkg = ThirdPartyPackage(
            id: pkg.id, displayName: pkg.displayName,
            description: pkg.description,
            source: .vendored(bundlePath: src.path),
            steps: pkg.steps)

        let runner = ManifestRunner(store: store, fetcher: VendoredSource())
        _ = try runner.install(pkg, into: "dev",
                               refOverride: nil, forceRefresh: false)
        try runner.uninstall(packageID: "statusline", from: "dev")

        let after = snapshot(at: claudeDir)
        #expect(after == before)
    }

    private func snapshot(at url: URL) -> Set<String> {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return []
        }
        var result = Set<String>()
        for case let file as URL in en {
            result.insert(file.path.replacingOccurrences(of: url.path, with: ""))
        }
        return result
    }
}
