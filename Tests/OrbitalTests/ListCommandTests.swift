import Testing
import Foundation
@testable import OrbitalCore

@Suite("ListCommand")
struct ListCommandTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbital-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("formats environment row with name and tools")
    func formatsRow() throws {
        let env = OrbitalEnvironment(name: "work", description: "Work", tools: [.claude, .codex])
        try store.save(env)

        let rows = try ListCommand.environmentRows(activeEnv: nil, store: store)
        #expect(rows.count == 1)
        #expect(rows[0].contains("work"))
        #expect(rows[0].contains("claude"))
        #expect(rows[0].contains("codex"))
    }

    @Test("marks active environment")
    func marksActive() throws {
        try store.save(OrbitalEnvironment(name: "work"))
        try store.save(OrbitalEnvironment(name: "personal"))

        let rows = try ListCommand.environmentRows(activeEnv: "work", store: store)
        let workRow = rows.first { $0.contains("work") }!
        #expect(workRow.contains("*"))
    }
}
