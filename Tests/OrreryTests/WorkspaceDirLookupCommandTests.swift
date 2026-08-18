import ArgumentParser
import Foundation
import Testing
@testable import OrreryCore

@Suite("WorkspaceDirLookupCommand")
struct WorkspaceDirLookupCommandTests {

    @Test("resolves origin without a UUID scan")
    func resolvesOrigin() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default
            let claudeDir = envStore.originConfigDir(tool: .claude)
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

            let output = try captureStdout {
                var cmd = try WorkspaceDirLookupCommand.parse(["origin", "--claude"])
                try cmd.run()
            }
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == claudeDir.path)
        }
    }

    @Test("resolves a UUID-keyed workspace by its name, not a literal path join")
    func resolvesUUIDKeyedWorkspaceByName() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default
            let env = Workspace(name: "work", tools: [.claude])
            try envStore.save(env)
            let claudeDir = envStore.toolConfigDir(tool: .claude, environment: "work")
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

            // The workspace's on-disk dir is keyed by UUID, not the literal name "work" —
            // a naive `<home>/workspaces/work/claude` join would miss it.
            #expect(!claudeDir.path.contains("/workspaces/work/"))

            let output = try captureStdout {
                var cmd = try WorkspaceDirLookupCommand.parse(["work", "--claude"])
                try cmd.run()
            }
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == claudeDir.path)
        }
    }

    @Test("throws ValidationError for an unknown workspace")
    func throwsForUnknownWorkspace() throws {
        try withIsolatedHome {
            var cmd = try WorkspaceDirLookupCommand.parse(["no-such-workspace", "--claude"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }

    @Test("throws ValidationError when the workspace exists but lacks that tool's dir")
    func throwsWhenToolDirMissing() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default
            let env = Workspace(name: "codex-only", tools: [.codex])
            try envStore.save(env)

            var cmd = try WorkspaceDirLookupCommand.parse(["codex-only", "--claude"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }

    @Test("rejects multiple tool flags")
    func rejectsMultipleFlags() throws {
        try withIsolatedHome {
            var cmd = try WorkspaceDirLookupCommand.parse(["origin", "--claude", "--codex"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }

    @Test("defaults to claude when no tool flag is given")
    func defaultsToClaudeTool() throws {
        try withIsolatedHome {
            let envStore = EnvironmentStore.default
            let claudeDir = envStore.originConfigDir(tool: .claude)
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

            let output = try captureStdout {
                var cmd = try WorkspaceDirLookupCommand.parse(["origin"])
                try cmd.run()
            }
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == claudeDir.path)
        }
    }
}
