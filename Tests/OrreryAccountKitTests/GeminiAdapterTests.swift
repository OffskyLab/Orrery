import Foundation
import Testing
import OrreryCore
@testable import OrreryAccountKit

private func withTempHome(_ body: (_ acctStore: AccountStore, _ envStore: EnvironmentStore) throws -> Void) throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gemini-adapter-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try body(AccountStore(homeURL: tmpDir), EnvironmentStore(homeURL: tmpDir))
}

@Suite("GeminiAdapter.prepareDirectory")
struct GeminiAdapterPrepareTests {
    let adapter = GeminiAdapter()

    @Test("creates account dir with a symlink for tmp (the only shared subdir)")
    func createsDirAndSymlink() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .gemini)
            let wsDir = envStore.toolConfigDir(tool: .gemini, environment: "origin")
            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("tmp").path)
            #expect(dest == wsDir.appendingPathComponent("tmp").path)
        }
    }

    @Test("runtime/credential files are never migrated into the workspace")
    func leavesCredentialsPrivate() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .gemini)
            try FileManager.default.createDirectory(at: acctDir, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: acctDir.appendingPathComponent("oauth_creds.json"))

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            #expect((try? FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("oauth_creds.json").path)) == nil)
            #expect((try? String(
                contentsOf: acctDir.appendingPathComponent("oauth_creds.json"), encoding: .utf8)) == "secret")
        }
    }

    @Test("throws when given a non-gemini account")
    func throwsOnWrongTool() throws {
        try withTempHome { acctStore, envStore in
            let acct = Account(tool: .codex, displayName: "test")
            try acctStore.save(acct)

            #expect(throws: GeminiAdapter.Error.self) {
                try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)
            }
        }
    }

    @Test("is idempotent")
    func isIdempotent() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .gemini)
            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("tmp").path)
            #expect(dest == envStore.toolConfigDir(tool: .gemini, environment: "origin")
                .appendingPathComponent("tmp").path)
        }
    }

    @Test("self-heals when the workspace side of tmp is a dangling symlink")
    func healsDanglingWorkspaceSideSymlink() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)

            let wsDir = envStore.toolConfigDir(tool: .gemini, environment: "origin")
            try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: wsDir.appendingPathComponent("tmp").path,
                withDestinationPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString)")

            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .gemini)
            let dest = try FileManager.default.destinationOfSymbolicLink(
                atPath: acctDir.appendingPathComponent("tmp").path)
            #expect(dest == wsDir.appendingPathComponent("tmp").path)
        }
    }
}

@Suite("GeminiAdapter.verifySymlinks")
struct GeminiAdapterVerifyTests {
    let adapter = GeminiAdapter()

    @Test("returns .ok for freshly prepared dir")
    func okAfterPrepare() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "t")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            #expect(adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore) == .ok)
        }
    }

    @Test("returns .notApplicable for a non-gemini account")
    func notApplicableForOtherTool() throws {
        try withTempHome { acctStore, envStore in
            let acct = Account(tool: .claude, displayName: "x")
            try acctStore.save(acct)

            #expect(adapter.verifySymlinks(account: acct, accountStore: acctStore, environmentStore: envStore) == .notApplicable)
        }
    }
}

@Suite("GeminiAdapter HOME-wrapper export")
struct GeminiAdapterExportTests {
    let adapter = GeminiAdapter()

    @Test("exportEnvVarName is ORRERY_GEMINI_HOME, not GEMINI_CONFIG_DIR")
    func exportsCorrectEnvVar() {
        // gemini-cli ignores GEMINI_CONFIG_DIR entirely — it only reads
        // $HOME/.gemini. Exporting the wrong var would silently do nothing.
        #expect(adapter.exportEnvVarName == "ORRERY_GEMINI_HOME")
    }

    @Test("resolvedExportPath creates a sibling wrapper dir with .gemini symlinked back to the account dir")
    func resolvedExportPathCreatesWrapper() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .gemini)
            let exportPath = try adapter.resolvedExportPath(accountDir: acctDir)

            // The wrapper lives outside accounts/gemini/ entirely (a sibling of
            // the gemini tool dir, not of the account dir) — nesting it inside
            // accounts/gemini/ would make AccountStore.list(tool: .gemini)
            // mistake it for a broken pool entry.
            #expect(exportPath.path != acctDir.path)
            #expect(!exportPath.path.hasPrefix(acctDir.deletingLastPathComponent().path + "/"),
                "wrapper must not live inside accounts/gemini/")
            // HOME=$exportPath must still resolve $HOME/.gemini to the real account dir.
            // Resolve via the filesystem itself (mirrors how the shell / gemini-cli
            // will actually follow the symlink) rather than hand-rolling relative
            // URL math, which is sensitive to trailing-slash representation.
            let resolved = exportPath.appendingPathComponent(".gemini").resolvingSymlinksInPath()
            #expect(resolved.path == acctDir.resolvingSymlinksInPath().path)
        }
    }

    @Test("accountID(fromExportPath:) recovers the account id from the wrapper path")
    func accountIDRoundTrips() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .gemini)
            let exportPath = try adapter.resolvedExportPath(accountDir: acctDir)
            #expect(adapter.accountID(fromExportPath: exportPath) == acct.id)
        }
    }

    @Test("the wrapper dir does not pollute AccountStore.list(tool: .gemini)")
    func wrapperDoesNotPolluteAccountPool() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .gemini)
            _ = try adapter.resolvedExportPath(accountDir: acctDir)

            let pool = try acctStore.list(tool: .gemini)
            #expect(pool.count == 1)
            #expect(pool.first?.id == acct.id)
        }
    }

    @Test("resolvedExportPath is idempotent")
    func resolvedExportPathIdempotent() throws {
        try withTempHome { acctStore, envStore in
            var acct = Account(tool: .gemini, displayName: "test")
            acct.workspace = "origin"
            try acctStore.save(acct)
            try adapter.prepareDirectory(account: acct, accountStore: acctStore, environmentStore: envStore)

            let acctDir = acctStore.accountDir(id: acct.id, tool: .gemini)
            let first = try adapter.resolvedExportPath(accountDir: acctDir)
            let second = try adapter.resolvedExportPath(accountDir: acctDir)
            #expect(first.path == second.path)
        }
    }
}
