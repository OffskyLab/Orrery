import Testing
import Foundation
@testable import OrreryCore

@Suite("FilesystemCredentialAdapter")
struct FilesystemCredentialAdapterTests {
    var tmpDir: URL!
    var accountStore: AccountStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-fs-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        accountStore = AccountStore(homeURL: tmpDir)
    }

    @Test("materialize symlinks codex auth.json into target dir")
    func materializeCodex() throws {
        let account = Account(tool: .codex, displayName: "work")
        try accountStore.save(account)

        let accountDir = accountStore.accountDir(id: account.id, tool: .codex)
        let credsURL = accountDir.appendingPathComponent("auth.json")
        try "{\"token\":\"abc\"}".data(using: .utf8)!.write(to: credsURL)

        let targetDir = tmpDir.appendingPathComponent("target-codex")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)

        let symlinked = targetDir.appendingPathComponent("auth.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: symlinked.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlinked.path)
        #expect(dest == credsURL.path)
    }

    @Test("materialize is idempotent (no-op when symlink already correct)")
    func idempotent() throws {
        let account = Account(tool: .codex, displayName: "work")
        try accountStore.save(account)
        let credsURL = accountStore.accountDir(id: account.id, tool: .codex)
            .appendingPathComponent("auth.json")
        try "{}".data(using: .utf8)!.write(to: credsURL)

        let targetDir = tmpDir.appendingPathComponent("target-codex-idem")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)
        // must not throw on the second call
    }

    @Test("materialize replaces stale symlink pointing elsewhere")
    func replacesStale() throws {
        let account = Account(tool: .codex, displayName: "new")
        try accountStore.save(account)
        let newCreds = accountStore.accountDir(id: account.id, tool: .codex)
            .appendingPathComponent("auth.json")
        try "{}".data(using: .utf8)!.write(to: newCreds)

        let targetDir = tmpDir.appendingPathComponent("target-codex-stale")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let symlink = targetDir.appendingPathComponent("auth.json")
        let staleTarget = tmpDir.appendingPathComponent("stale.json")
        try "{}".data(using: .utf8)!.write(to: staleTarget)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: staleTarget)

        let adapter = FilesystemCredentialAdapter(tool: .codex)
        try adapter.materialize(account: account, targetConfigDir: targetDir, accountStore: accountStore)

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
        #expect(dest == newCreds.path)
    }
}
