import Testing
import Foundation
@testable import OrreryCore

@Suite("EnvironmentStore.lastUsed")
struct LastUsedTests {
    private func tempStore() throws -> (EnvironmentStore, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-lastused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (EnvironmentStore(homeURL: home), home)
    }

    @Test("returns nil when no session files exist")
    func empty() throws {
        let (store, _) = try tempStore()
        try store.save(OrreryEnvironment(name: "work", tools: [.claude]))
        #expect(store.lastUsed(tool: .claude, environment: "work") == nil)
    }

    @Test("returns the newest mtime across session subdirs")
    func newestMtime() throws {
        let (store, _) = try tempStore()
        try store.save(OrreryEnvironment(name: "work", tools: [.claude]))
        let claudeDir = store.toolConfigDir(tool: .claude, environment: "work")
        let projects = claudeDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let oldFile = projects.appendingPathComponent("old.jsonl")
        let newFile = projects.appendingPathComponent("new.jsonl")
        try Data("old".utf8).write(to: oldFile)
        try Data("new".utf8).write(to: newFile)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_777_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newFile.path)

        let result = store.lastUsed(tool: .claude, environment: "work")
        #expect(result == newDate)
    }

    @Test("follows symlinked session subdirs (shared sessions mode)")
    func symlinked() throws {
        let (store, home) = try tempStore()
        try store.save(OrreryEnvironment(name: "work", tools: [.codex]))
        let codexDir = store.toolConfigDir(tool: .codex, environment: "work")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        // Real sessions dir lives elsewhere; codex/sessions is just a symlink.
        let real = home.appendingPathComponent("shared-sessions")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("session.json")
        try Data("x".utf8).write(to: file)
        let mtime = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        let link = codexDir.appendingPathComponent("sessions")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(store.lastUsed(tool: .codex, environment: "work") == mtime)
    }
}
