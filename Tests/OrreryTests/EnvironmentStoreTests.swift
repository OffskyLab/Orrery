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

    @Test("creates environment directory and env.json")
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
        // Parent is a UUID dir, not the env name — just verify it's under envsURL
        let envsURL = tmpDir.appendingPathComponent("envs")
        #expect(path.path.hasPrefix(envsURL.path))
    }
}
