import Testing
import Foundation
@testable import OrreryCore

@Suite("CreateCommand")
struct CreateCommandTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("creates a new single-tool environment")
    func createNew() throws {
        try CreateCommand.createEnvironment(
            name: "work",
            description: "Work account",
            tool: .claude,
            store: store
        )
        let env = try store.load(named: "work")
        #expect(env.name == "work")
        #expect(env.description == "Work account")
        #expect(env.tools == [.claude])
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "work")
        #expect(FileManager.default.fileExists(atPath: claudeDir.path))
    }

    @Test("createEnvironment with shareUserMemory=false persists the flag")
    func createPersistsShareUserMemoryFalse() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-create-shareuser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        try CreateCommand.createEnvironment(
            name: "demo",
            description: "",
            tool: .claude,
            isolateSessions: false,
            isolateMemory: false,
            shareUserMemory: false,
            store: store
        )
        let env = try store.load(named: "demo")
        #expect(env.shareUserMemory == false)
    }

    @Test("createEnvironment defaults shareUserMemory to true")
    func createDefaultsShareUserMemory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-create-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        try CreateCommand.createEnvironment(
            name: "demo",
            description: "",
            tool: .claude,
            store: store
        )
        let env = try store.load(named: "demo")
        #expect(env.shareUserMemory == true)
    }
}
