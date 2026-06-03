import Testing
import Foundation
@testable import OrreryCore

@Suite("EnvironmentStore")
struct EnvironmentStoreTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("creates environment directory and workspace.json")
    func createEnvironment() throws {
        let env = OrreryEnvironment(name: "work", description: "Work")
        try store.save(env)
        let loaded = try store.load(named: "work")
        #expect(loaded.name == "work")
        #expect(loaded.description == "Work")
    }

    @Test("lists all environments")
    func listEnvironments() throws {
        try store.save(OrreryEnvironment(name: "work"))
        try store.save(OrreryEnvironment(name: "personal"))
        let names = try store.listNames()
        #expect(names.sorted() == ["personal", "work"])
    }

    @Test("deletes environment")
    func deleteEnvironment() throws {
        try store.save(OrreryEnvironment(name: "work"))
        try store.delete(named: "work")
        let names = try store.listNames()
        #expect(names.isEmpty)
    }

    @Test("load throws when environment does not exist")
    func loadMissing() throws {
        #expect(throws: EnvironmentStore.Error.self) {
            try store.load(named: "nonexistent")
        }
    }

    @Test("saves and loads current environment name")
    func currentEnvironment() throws {
        try store.save(OrreryEnvironment(name: "work"))
        try store.setCurrent("work")
        #expect(try store.current() == "work")
    }

    @Test("current returns nil when not set")
    func currentNilWhenUnset() throws {
        #expect(try store.current() == nil)
    }

    @Test("creates tool subdirectory")
    func createToolDirectory() throws {
        try store.save(OrreryEnvironment(name: "work"))
        try store.addTool(.claude, to: "work")
        let toolDir = store.toolConfigDir(tool: .claude, environment: "work")
        #expect(FileManager.default.fileExists(atPath: toolDir.path))
    }

    @Test("tool config dir path")
    func toolConfigDirPath() throws {
        try store.save(OrreryEnvironment(name: "work"))
        let path = store.toolConfigDir(tool: .claude, environment: "work")
        #expect(path.lastPathComponent == "claude")
        // Parent is a UUID dir, not the env name — just verify it's under workspaces/
        let workspacesURL = tmpDir.appendingPathComponent("workspaces")
        #expect(path.path.hasPrefix(workspacesURL.path))
    }
}

@Suite("EnvironmentStore.accounts")
struct EnvironmentAccountsTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-env-accts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("workspace.json round-trips accounts field")
    func roundTripAccounts() throws {
        var env = OrreryEnvironment(name: "work")
        env.accounts = ["claude": "acct-123", "codex": "acct-456"]
        try store.save(env)
        let loaded = try store.load(named: "work")
        #expect(loaded.accounts["claude"] == "acct-123")
        #expect(loaded.accounts["codex"] == "acct-456")
        #expect(loaded.accounts["gemini"] == nil)
    }

    @Test("default empty accounts")
    func defaultEmpty() throws {
        let env = OrreryEnvironment(name: "empty")
        try store.save(env)
        let loaded = try store.load(named: "empty")
        #expect(loaded.accounts.isEmpty)
    }

    @Test("decodes legacy workspace.json without accounts key")
    func legacyDecode() throws {
        let json = """
        {"id":"x","name":"old","description":"","createdAt":"2026-01-01T00:00:00Z","lastUsed":"2026-01-01T00:00:00Z","tools":[],"env":{},"isolatedSessionTools":[],"isolateMemory":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let env = try decoder.decode(OrreryEnvironment.self, from: Data(json.utf8))
        #expect(env.accounts.isEmpty)
    }

    @Test("decodes legacy origin config.json without accounts key")
    func legacyOriginDecode() throws {
        let json = """
        {"isolateMemory":true,"isolatedSessionTools":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cfg = try decoder.decode(OrreryEnvironment.self, from: Data(json.utf8))
        #expect(cfg.accounts.isEmpty)
        #expect(cfg.name == "origin")
    }

    @Test("account(for:) and setAccount(_:for:) helpers")
    func helpers() throws {
        var env = OrreryEnvironment(name: "h")
        env.setAccount("a1", for: .claude)
        #expect(env.account(for: .claude) == "a1")
        env.setAccount(nil, for: .claude)
        #expect(env.account(for: .claude) == nil)
    }

    @Test("envsReferencing returns envs that pin given account")
    func envsReferencing() throws {
        var work = OrreryEnvironment(name: "work")
        work.accounts["claude"] = "shared-acct"
        try store.save(work)
        var play = OrreryEnvironment(name: "play")
        play.accounts["claude"] = "shared-acct"
        play.accounts["codex"] = "other"
        try store.save(play)
        var lonely = OrreryEnvironment(name: "lonely")
        lonely.accounts["codex"] = "different"
        try store.save(lonely)

        let refs = try store.envsReferencing(accountID: "shared-acct", tool: .claude)
        #expect(Set(refs) == ["work", "play"])
    }

    @Test("envsReferencing includes origin when origin pins the account")
    func envsReferencingOrigin() throws {
        var origin = store.loadOriginConfig()
        origin.accounts["claude"] = "origin-acct"
        try store.saveOriginConfig(origin)
        let refs = try store.envsReferencing(accountID: "origin-acct", tool: .claude)
        #expect(refs.contains(ReservedEnvironment.defaultName))
    }

    @Test("empty accounts is omitted from workspace.json")
    func emptyAccountsOmitted() throws {
        let env = OrreryEnvironment(name: "noacct")
        try store.save(env)
        let workspacesDir = tmpDir.appendingPathComponent("workspaces")
        let idDir = try FileManager.default.contentsOfDirectory(atPath: workspacesDir.path).first!
        let jsonURL = workspacesDir.appendingPathComponent(idDir).appendingPathComponent("workspace.json")
        let raw = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(!raw.contains("\"accounts\""))
    }
}
