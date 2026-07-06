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

    /// A package whose steps target the workspace via the marker.
    private func workspacePkg(_ srcDir: URL) -> ThirdPartyPackage {
        ThirdPartyPackage(
            id: "statusline",
            displayName: "statusline",
            description: "",
            source: .vendored(bundlePath: srcDir.path),
            steps: [
                .copyFile(from: "statusline.js", to: "<WORKSPACE_CLAUDE_DIR>/statusline.js"),
                .patchSettings(file: "settings.json", patch: .object([
                    "statusLine": .object([
                        "command": .string("node <WORKSPACE_CLAUDE_DIR>/statusline.js")
                    ])
                ]))
            ]
        )
    }

    /// The fixture pins `test-acct` to workspace `dev`; a real pinned account
    /// records that in metadata.json, so write it (resolveWorkspaceClaudeDir
    /// reads this field).
    private func writeAccountWorkspace(_ store: EnvironmentStore, _ workspace: String) throws {
        let acctDir = AccountStore(homeURL: store.homeURL).accountDir(id: "test-acct", tool: .claude)
        try Data("{\"workspace\":\"\(workspace)\"}".utf8)
            .write(to: acctDir.appendingPathComponent("metadata.json"))
    }

    @Test("workspace-targeted install lands the script in the workspace and points account settings at it")
    func workspaceInstall() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        try writeAccountWorkspace(store, "dev")

        let record = try runner.install(workspacePkg(srcDir), into: envName,
                                        refOverride: nil, forceRefresh: false)
        let fm = FileManager.default
        let wsDir = store.claudeWorkspaceDir(workspace: "dev")
        let acctDir = AccountStore(homeURL: store.homeURL).accountDir(id: "test-acct", tool: .claude)

        // Script is in the workspace, NOT the account dir.
        #expect(fm.fileExists(atPath: wsDir.appendingPathComponent("statusline.js").path))
        #expect(!fm.fileExists(atPath: acctDir.appendingPathComponent("statusline.js").path))
        // Lock keeps the marker verbatim.
        #expect(record.copiedFiles == ["<WORKSPACE_CLAUDE_DIR>/statusline.js"])
        // settings.json is in the ACCOUNT dir and points at the workspace path.
        let settings = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: acctDir.appendingPathComponent("settings.json")))
        guard case .object(let o) = settings, case .object(let sl) = o["statusLine"],
              case .string(let cmd) = sl["command"] else { Issue.record("shape"); return }
        #expect(cmd == "node \(wsDir.path)/statusline.js")
    }

    @Test("uninstall removes the workspace script and reverts account settings")
    func uninstallWorkspace() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        try writeAccountWorkspace(store, "dev")
        _ = try runner.install(workspacePkg(srcDir), into: envName, refOverride: nil, forceRefresh: false)
        try runner.uninstall(packageID: "statusline", from: envName)

        let fm = FileManager.default
        let wsDir = store.claudeWorkspaceDir(workspace: "dev")
        let acctDir = AccountStore(homeURL: store.homeURL).accountDir(id: "test-acct", tool: .claude)
        #expect(!fm.fileExists(atPath: wsDir.appendingPathComponent("statusline.js").path))
        #expect(!fm.fileExists(atPath: acctDir.appendingPathComponent(".thirdparty/statusline.lock.json").path))
        // statusLine removed from account settings (file removed if it became empty).
        if let data = try? Data(contentsOf: acctDir.appendingPathComponent("settings.json")),
           case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: data) {
            #expect(o["statusLine"] == nil)
        }
    }
}
