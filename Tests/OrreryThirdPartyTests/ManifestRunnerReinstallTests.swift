import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("ManifestRunner — reinstall")
struct ManifestRunnerReinstallTests {
    @Test("installing over an existing lock first uninstalls, then reinstalls")
    func reinstallAutoUninstalls() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-reinst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: home)
        var ws = Workspace(name: "dev")
        ws.setAccount("test-acct", for: .claude)
        try store.save(ws)
        // v3.1: third-party installs target the account dir, not the workspace.
        try FileManager.default.createDirectory(
            at: AccountStore(homeURL: home).accountDir(id: "test-acct", tool: .claude),
            withIntermediateDirectories: true)
        let src = home.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: src.appendingPathComponent("statusline.js"))
        let pkg = ThirdPartyPackage(
            id: "cc-statusline", displayName: "cc", description: "",
            source: .vendored(bundlePath: src.path),
            steps: [.copyFile(from: "statusline.js", to: "statusline.js")]
        )
        let runner = ManifestRunner(store: store, fetcher: VendoredSource())
        _ = try runner.install(pkg, into: "dev", refOverride: nil, forceRefresh: false)

        try Data("v2".utf8).write(to: src.appendingPathComponent("statusline.js"))
        _ = try runner.install(pkg, into: "dev", refOverride: nil, forceRefresh: false)

        let claudeDir = AccountStore(homeURL: store.homeURL).accountDir(id: "test-acct", tool: .claude)
        let content = try String(contentsOf: claudeDir.appendingPathComponent("statusline.js"),
                                 encoding: .utf8)
        #expect(content == "v2")
        let records = try runner.listInstalled(in: "dev")
        #expect(records.count == 1)
    }
}
