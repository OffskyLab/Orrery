import Testing
import Foundation
@testable import OrreryCore

@Suite("SandboxCommand.List")
struct ListCommandTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("formats environment row with name and tools")
    func formatsRow() throws {
        let env = Workspace(name: "work", description: "Work", tools: [.claude, .codex])
        try store.save(env)

        let rows = try SandboxCommand.List.environmentRows(activeEnv: nil, store: store)
        // default is always included as the first row
        #expect(rows.count == 2)
        let workRow = rows.first { $0.contains("work") }!
        #expect(workRow.contains("claude"))
        #expect(workRow.contains("codex"))
    }

    @Test("marks active environment")
    func marksActive() throws {
        try store.save(Workspace(name: "work"))
        try store.save(Workspace(name: "personal"))

        let rows = try SandboxCommand.List.environmentRows(activeEnv: "work", store: store)
        let workRow = rows.first { $0.contains("work") }!
        #expect(workRow.contains("*"))
    }
}
