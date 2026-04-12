import Testing
import Foundation
@testable import OrreryCore

@Suite("Configuration Commands")
struct ConfigCommandTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
        try store.save(OrreryEnvironment(name: "work"))
    }

    @Test("set env stores key-value in env.json")
    func setEnv() throws {
        var env = try store.load(named: "work")
        env.env["MY_KEY"] = "my-value"
        try store.save(env)
        let loaded = try store.load(named: "work")
        #expect(loaded.env["MY_KEY"] == "my-value")
    }

    @Test("unset env removes key from env.json")
    func unsetEnv() throws {
        var env = try store.load(named: "work")
        env.env["MY_KEY"] = "my-value"
        try store.save(env)
        var updated = try store.load(named: "work")
        updated.env.removeValue(forKey: "MY_KEY")
        try store.save(updated)
        let loaded = try store.load(named: "work")
        #expect(loaded.env["MY_KEY"] == nil)
    }

    @Test("add tool creates subdirectory and updates env.json")
    func addTool() throws {
        try store.addTool(.claude, to: "work")
        let env = try store.load(named: "work")
        #expect(env.tools.contains(.claude))
        let toolDir = store.toolConfigDir(tool: .claude, environment: "work")
        #expect(FileManager.default.fileExists(atPath: toolDir.path))
    }

    @Test("remove tool removes subdirectory and updates env.json")
    func removeTool() throws {
        try store.addTool(.claude, to: "work")
        try store.removeTool(.claude, from: "work")
        let env = try store.load(named: "work")
        #expect(!env.tools.contains(.claude))
    }
}
