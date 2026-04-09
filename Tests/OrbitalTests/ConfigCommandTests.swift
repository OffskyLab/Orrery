import Testing
import Foundation
@testable import OrbitalCore

@Suite("Configuration Commands")
struct ConfigCommandTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbital-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
        try store.save(OrbitalEnvironment(name: "work"))
    }

    @Test("set env stores key-value in env.json")
    func setEnv() throws {
        try SetEnvCommand.setEnvVar(key: "MY_KEY", value: "my-value", environmentName: "work", store: store)
        let env = try store.load(named: "work")
        #expect(env.env["MY_KEY"] == "my-value")
    }

    @Test("unset env removes key from env.json")
    func unsetEnv() throws {
        try SetEnvCommand.setEnvVar(key: "MY_KEY", value: "my-value", environmentName: "work", store: store)
        try UnsetEnvCommand.unsetEnvVar(key: "MY_KEY", environmentName: "work", store: store)
        let env = try store.load(named: "work")
        #expect(env.env["MY_KEY"] == nil)
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
