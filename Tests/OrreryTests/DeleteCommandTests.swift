import Testing
import Foundation
@testable import OrreryCore

@Suite("DeleteCommand")
struct DeleteCommandTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("deletes environment when force is true")
    func forceDelete() throws {
        try store.save(OrreryEnvironment(name: "work"))
        try DeleteCommand.deleteEnvironment(name: "work", force: true, store: store)
        let names = try store.listNames()
        #expect(names.isEmpty)
    }

    @Test("throws when environment not found")
    func deleteMissing() throws {
        #expect(throws: (any Error).self) {
            try DeleteCommand.deleteEnvironment(name: "nonexistent", force: true, store: store)
        }
    }
}
