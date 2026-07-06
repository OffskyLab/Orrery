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

    /// The fixture pins workspace `dev` to account `test-acct`; a real pinned
    /// account records its workspace in a properly-encoded `Account`
    /// metadata.json — so `AccountStore.list(tool:.claude)` returns it (which
    /// `otherAccountReferences` relies on to iterate/self-exclude the uninstalling
    /// account) and `resolveWorkspaceName` reads its `workspace` field.
    private func writeAccountWorkspace(_ store: EnvironmentStore, _ workspace: String) throws {
        let acctStore = AccountStore(homeURL: store.homeURL)
        try acctStore.save(Account(id: "test-acct", tool: .claude,
                                   displayName: "t", workspace: workspace))
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

    @Test("install throws on a stale/unknown workspace pin and writes nothing")
    func badWorkspacePinThrows() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        // Point the account at a workspace that was never created.
        try writeAccountWorkspace(store, "ghost-ws")

        #expect(throws: ThirdPartyError.self) {
            _ = try runner.install(workspacePkg(srcDir), into: envName,
                                   refOverride: nil, forceRefresh: false)
        }
        // No phantom workspace file written.
        let ghost = store.claudeWorkspaceDir(workspace: "ghost-ws")
            .appendingPathComponent("statusline.js")
        #expect(!FileManager.default.fileExists(atPath: ghost.path))
    }

    @Test("uninstall keeps the shared workspace file while another account references it")
    func uninstallRefcountsSharedFile() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        try writeAccountWorkspace(store, "dev")
        _ = try runner.install(workspacePkg(srcDir), into: envName,
                               refOverride: nil, forceRefresh: false)

        let acctStore = AccountStore(homeURL: store.homeURL)
        let wsFile = store.claudeWorkspaceDir(workspace: "dev")
            .appendingPathComponent("statusline.js")
        #expect(FileManager.default.fileExists(atPath: wsFile.path))

        // Plant a SECOND account, pinned to "dev", with its own lock recording
        // the same workspace + marker (simulating it also installed).
        let acct2 = Account(tool: .claude, displayName: "acct2")
        try acctStore.save(acct2)
        let acct2Dir = acctStore.accountDir(id: acct2.id, tool: .claude)
        let acct2Third = acct2Dir.appendingPathComponent(".thirdparty")
        try FileManager.default.createDirectory(at: acct2Third, withIntermediateDirectories: true)
        let coTenant = InstallRecord(
            packageID: "statusline", resolvedRef: "x", manifestRef: "latest",
            installedAt: Date(),
            copiedFiles: ["<WORKSPACE_CLAUDE_DIR>/statusline.js"],
            patchedSettings: [], workspace: "dev")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(coTenant).write(to: acct2Third.appendingPathComponent("statusline.lock.json"))

        // Uninstall the first account — shared file must SURVIVE (co-tenant refs it).
        try runner.uninstall(packageID: "statusline", from: envName)
        #expect(FileManager.default.fileExists(atPath: wsFile.path))

        // Remove the co-tenant's lock, then uninstalling again would delete it —
        // but the first account's lock is already gone, so instead verify the
        // refcount helper's contract via a fresh install+uninstall with no co-tenant:
        try FileManager.default.removeItem(at: acct2Third.appendingPathComponent("statusline.lock.json"))
        _ = try runner.install(workspacePkg(srcDir), into: envName,
                               refOverride: nil, forceRefresh: false)
        try runner.uninstall(packageID: "statusline", from: envName)
        #expect(!FileManager.default.fileExists(atPath: wsFile.path))
    }

    @Test("uninstall removes the file installed under the ORIGINAL workspace after a re-pin")
    func uninstallUsesInstallTimeWorkspace() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        try writeAccountWorkspace(store, "dev")
        _ = try runner.install(workspacePkg(srcDir), into: envName, refOverride: nil, forceRefresh: false)
        let devFile = store.claudeWorkspaceDir(workspace: "dev").appendingPathComponent("statusline.js")
        #expect(FileManager.default.fileExists(atPath: devFile.path))
        // Re-pin the account's metadata to a different workspace AFTER install.
        try writeAccountWorkspace(store, "team")
        // Uninstall must remove the file it actually installed (dev), via record.workspace.
        try runner.uninstall(packageID: "statusline", from: envName)
        #expect(!FileManager.default.fileExists(atPath: devFile.path))
    }

    @Test("a co-tenant lock recording a DIFFERENT workspace does not block deletion")
    func refcountIgnoresDifferentWorkspace() throws {
        let (store, envName, srcDir, runner) = try setupFixture()
        try writeAccountWorkspace(store, "dev")
        _ = try runner.install(workspacePkg(srcDir), into: envName, refOverride: nil, forceRefresh: false)
        let devFile = store.claudeWorkspaceDir(workspace: "dev").appendingPathComponent("statusline.js")

        // A second account whose lock references a DIFFERENT workspace ("other").
        let acctStore = AccountStore(homeURL: store.homeURL)
        let acct2 = Account(tool: .claude, displayName: "acct2")
        try acctStore.save(acct2)
        let third = acctStore.accountDir(id: acct2.id, tool: .claude).appendingPathComponent(".thirdparty")
        try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
        let other = InstallRecord(packageID: "statusline", resolvedRef: "x", manifestRef: "latest",
            installedAt: Date(), copiedFiles: ["<WORKSPACE_CLAUDE_DIR>/statusline.js"],
            patchedSettings: [], workspace: "other")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(other).write(to: third.appendingPathComponent("statusline.lock.json"))

        // Different workspace → NOT a co-tenant of "dev" → file is deleted.
        try runner.uninstall(packageID: "statusline", from: envName)
        #expect(!FileManager.default.fileExists(atPath: devFile.path))
    }
}
