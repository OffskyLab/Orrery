import Testing
import Foundation
@testable import OrreryCore

@Suite("RenameCommand")
struct RenameCommandTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("renames environment directory and updates name field")
    func renamesEnvironment() throws {
        try store.save(OrreryEnvironment(name: "work"))
        try RenameCommand.renameEnvironment(from: "work", to: "office", store: store)

        let env = try store.load(named: "office")
        #expect(env.name == "office")

        let names = try store.listNames()
        #expect(names == ["office"])
    }

    @Test("preserves tool config directories after rename")
    func preservesToolDirs() throws {
        try store.save(OrreryEnvironment(name: "work", tools: [.claude]))
        try store.addTool(.claude, to: "work")
        try RenameCommand.renameEnvironment(from: "work", to: "office", store: store)

        let toolDir = store.toolConfigDir(tool: .claude, environment: "office")
        #expect(FileManager.default.fileExists(atPath: toolDir.path))
    }

    @Test("updates current pointer when renaming active environment")
    func updatesCurrentPointer() throws {
        try store.save(OrreryEnvironment(name: "work"))
        try store.setCurrent("work")
        try RenameCommand.renameEnvironment(from: "work", to: "office", store: store)

        #expect(try store.current() == "office")
    }

    @Test("throws when source environment does not exist")
    func throwsWhenMissing() throws {
        #expect(throws: (any Error).self) {
            try RenameCommand.renameEnvironment(from: "nonexistent", to: "other", store: store)
        }
    }
}
