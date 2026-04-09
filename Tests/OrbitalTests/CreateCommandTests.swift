import Testing
import Foundation
@testable import OrbitalCore

@Suite("CreateCommand")
struct CreateCommandTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbital-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("creates a new environment")
    func createNew() throws {
        try CreateCommand.createEnvironment(name: "work", description: "Work account", cloneFrom: nil, store: store)
        let env = try store.load(named: "work")
        #expect(env.name == "work")
        #expect(env.description == "Work account")
        #expect(env.tools.isEmpty)
    }

    @Test("clone copies tools and env vars but not config dirs")
    func cloneEnvironment() throws {
        let source = OrbitalEnvironment(name: "work", tools: [.claude], env: ["ANTHROPIC_API_KEY": "sk-test"])
        try store.save(source)
        try store.addTool(.claude, to: "work")

        try CreateCommand.createEnvironment(name: "work2", description: "", cloneFrom: "work", store: store)

        let cloned = try store.load(named: "work2")
        #expect(cloned.tools == [.claude])
        #expect(cloned.env["ANTHROPIC_API_KEY"] == "sk-test")
        // Config dir is created (tool is added) but contents are not copied from source
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "work2")
        #expect(FileManager.default.fileExists(atPath: claudeDir.path))
    }
}
