import Testing
import Foundation
@testable import OrreryCore

@Suite("EnvironmentStore user memory paths")
struct EnvironmentStoreUserMemoryTests {

    @Test("userMemoryDir is ~/.orrery/user/memory under the store home")
    func userMemoryDirPath() {
        let home = URL(fileURLWithPath: "/tmp/fake-orrery-home")
        let store = EnvironmentStore(homeURL: home)
        #expect(store.userMemoryDir().path == "/tmp/fake-orrery-home/user/memory")
    }

    @Test("ensureUserMemoryHooks installs hooks for each installed tool")
    func ensureInstallsForEachTool() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-ensurehooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)

        var env = OrreryEnvironment(name: "e1", tools: [.claude, .codex])
        try store.save(env)
        // Pre-create tool config dirs so the installers have a place to write.
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "e1")
        let codexDir = store.toolConfigDir(tool: .codex, environment: "e1")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        try store.ensureUserMemoryHooks(for: "e1")

        #expect(ClaudeHookInstaller().isInstalled(at: claudeDir))
        #expect(CodexHookInstaller().isInstalled(at: codexDir))
    }

    @Test("ensureUserMemoryHooks skips installation when shareUserMemory is false")
    func ensureSkipsWhenDisabled() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-ensurehooks-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        var env = OrreryEnvironment(name: "e2", tools: [.claude], shareUserMemory: false)
        try store.save(env)
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "e2")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        try store.ensureUserMemoryHooks(for: "e2")
        #expect(!ClaudeHookInstaller().isInstalled(at: claudeDir))
    }

    @Test("removeUserMemoryHooks removes from all tools")
    func removeFromAllTools() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-removehooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        var env = OrreryEnvironment(name: "e3", tools: [.claude, .codex])
        try store.save(env)
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "e3")
        let codexDir = store.toolConfigDir(tool: .codex, environment: "e3")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        try store.ensureUserMemoryHooks(for: "e3")
        try store.removeUserMemoryHooks(for: "e3")
        #expect(!ClaudeHookInstaller().isInstalled(at: claudeDir))
        #expect(!CodexHookInstaller().isInstalled(at: codexDir))
    }

    @Test("addTool installs user-memory hook on the new tool when shareUserMemory=true")
    func addToolInstallsHook() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-addtoolhook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: tmp)
        var env = OrreryEnvironment(name: "e", tools: [], shareUserMemory: true)
        try store.save(env)
        try store.addTool(.claude, to: "e")
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "e")
        #expect(ClaudeHookInstaller().isInstalled(at: claudeDir))
    }
}
