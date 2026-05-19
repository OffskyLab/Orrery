import Testing
import Foundation
@testable import OrreryCore

@Suite("UserMemoryCommand")
struct UserMemoryCommandTests {

    @Test("emit prints empty string when no memory file exists")
    func emitEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-uemit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        let output = try UserMemoryCommand.emit(store: store)
        #expect(output == "")
    }

    @Test("emit prints MEMORY.md content when present")
    func emitWithFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-uemit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        let dir = store.userMemoryDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "global memory".write(to: dir.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let output = try UserMemoryCommand.emit(store: store)
        #expect(output == "global memory")
    }

    @Test("enable sets shareUserMemory=true and installs hooks for current env")
    func enableInstallsHooks() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-enable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        var env = OrreryEnvironment(name: "e", tools: [.claude], shareUserMemory: false)
        try store.save(env)
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "e")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        try UserMemoryCommand.applyEnable(envName: "e", store: store)

        let updated = try store.load(named: "e")
        #expect(updated.shareUserMemory == true)
        #expect(ClaudeHookInstaller().isInstalled(at: claudeDir))
    }

    @Test("disable sets shareUserMemory=false and removes hooks")
    func disableRemovesHooks() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-disable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        var env = OrreryEnvironment(name: "e", tools: [.claude], shareUserMemory: true)
        try store.save(env)
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "e")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try store.ensureUserMemoryHooks(for: "e")

        try UserMemoryCommand.applyDisable(envName: "e", store: store)

        let updated = try store.load(named: "e")
        #expect(updated.shareUserMemory == false)
        #expect(!ClaudeHookInstaller().isInstalled(at: claudeDir))
    }
}
