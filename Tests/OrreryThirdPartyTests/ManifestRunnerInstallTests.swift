import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("ManifestRunner — install")
struct ManifestRunnerInstallTests {
    private func setupFixture() throws -> (store: EnvironmentStore, envName: String, sourceDir: URL, runner: ManifestRunner) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: home)
        var env = Workspace(name: "dev")
        env.setAccount("test-acct", for: .claude)
        try store.save(env)
        // v3.1: third-party installs target the account dir, not the workspace.
        try FileManager.default.createDirectory(
            at: AccountStore(homeURL: home).accountDir(id: "test-acct", tool: .claude),
            withIntermediateDirectories: true
        )

        let src = home.appendingPathComponent("src")
        let hooks = src.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Data("// statusline".utf8).write(to: src.appendingPathComponent("statusline.js"))
        try Data("// tracker".utf8).write(to: hooks.appendingPathComponent("file-tracker.js"))

        let runner = ManifestRunner(store: store, fetcher: VendoredSource())
        return (store, "dev", src, runner)
    }

    @Test("install copies files, patches settings, writes lock file")
    func happyPath() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        let pkg = ThirdPartyPackage(
            id: "cc-statusline",
            displayName: "cc-statusline",
            description: "",
            source: .vendored(bundlePath: srcDir.path),
            steps: [
                .copyFile(from: "statusline.js", to: "statusline.js"),
                .copyGlob(from: "hooks/*.js", toDir: "hooks"),
                .patchSettings(file: "settings.json", patch: .object([
                    "statusLine": .object(["command": .string("node <CLAUDE_DIR>/statusline.js")])
                ]))
            ]
        )

        let record = try runner.install(pkg, into: envName,
                                        refOverride: nil, forceRefresh: false)
        #expect(record.packageID == "cc-statusline")
        #expect(record.copiedFiles.contains("statusline.js"))
        #expect(record.copiedFiles.contains("hooks/file-tracker.js"))

        let claudeDir = AccountStore(homeURL: store.homeURL).accountDir(id: "test-acct", tool: .claude)
        #expect(FileManager.default.fileExists(
            atPath: claudeDir.appendingPathComponent("statusline.js").path))
        #expect(FileManager.default.fileExists(
            atPath: claudeDir.appendingPathComponent(".thirdparty/cc-statusline.lock.json").path))

        let settings = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
        )
        guard case .object(let o) = settings,
              case .object(let sl) = o["statusLine"],
              case .string(let cmd) = sl["command"] else {
            Issue.record("shape mismatch"); return
        }
        #expect(cmd.hasPrefix("node \(claudeDir.path)/"))
    }
}
