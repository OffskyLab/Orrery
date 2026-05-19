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
}
