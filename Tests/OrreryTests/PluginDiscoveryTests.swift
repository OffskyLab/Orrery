import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

@Suite("PluginDiscovery")
struct PluginDiscoveryTests {

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test("an explicit env var wins over every other location")
    func envVarWins() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-env-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("orrery-claude")
        try makeExecutable(at: bin)
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = PluginDiscovery.locate(
            toolID: "claude",
            environment: ["ORRERY_CLAUDE_PATH": bin.path])
        #expect(found?.path == bin.path)
    }

    @Test("a missing plugin is absent rather than an error")
    func missingPluginIsNil() {
        let found = PluginDiscovery.locate(
            toolID: "nosuchtool",
            environment: ["ORRERY_HOME": "/nonexistent-\(UUID().uuidString)"])
        #expect(found == nil)
    }

    @Test("an env var pointing at something unexecutable is ignored, not trusted")
    func unexecutablePathIgnored() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plain-\(UUID().uuidString).txt")
        try Data("not a binary".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let found = PluginDiscovery.locate(
            toolID: "claude",
            environment: ["ORRERY_CLAUDE_PATH": file.path,
                          "ORRERY_HOME": "/nonexistent-\(UUID().uuidString)"])
        #expect(found == nil)
    }
}
