import Foundation
import Testing
@testable import OrreryCore

/// `~/.claude`, `~/.codex` and `~/.gemini` are symlinks the origin takeover
/// owns, but nothing stops another process running as the same user from
/// repointing them — a verification script left all three aimed at
/// `/tmp/orrery-dispatch-test/...`, and once that scratch tree was cleaned
/// up every link dangled. The tools then fail against a path the user never
/// chose (gemini-cli's `mkdir` follows the link and reports `ENOENT` for a
/// directory it cannot explain).
///
/// Every test drives the parameterized entry point with an explicit `link`,
/// so nothing here can reach the developer's real home — the same lesson as
/// commit af08548, where a helper that resolved `tool.defaultConfigDir`
/// internally quietly hijacked the real `~/.claude`.
@Suite("origin home-symlink healing")
struct OriginSymlinkHealingTests {

    private func tmpHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-heal-\(UUID().uuidString)")
    }

    @Test("a dangling home symlink is repointed at the origin workspace dir")
    func healsDanglingSymlink() throws {
        let fm = FileManager.default
        let home = tmpHome()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        // A link aimed at a scratch tree that no longer exists.
        let link = home.appendingPathComponent("dot-gemini")
        let deadTarget = home.appendingPathComponent("scratch-that-was-cleaned-up/gemini")
        try fm.createSymbolicLink(at: link, withDestinationURL: deadTarget)
        #expect(!fm.fileExists(atPath: link.path), "precondition: the link dangles")

        AccountMigration.healDanglingOriginSymlink(link: link, tool: .gemini, homeURL: home)

        let expected = EnvironmentStore(homeURL: home).originConfigDir(tool: .gemini)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == expected.path)
        // …and the target has to actually exist, or the link still dangles.
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: expected.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test("a symlink whose target exists is left alone, even pointing outside the orrery home")
    func leavesLiveSymlinkAlone() throws {
        let fm = FileManager.default
        let home = tmpHome()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        // A deliberate link to somewhere real — it may hold the user's data,
        // so healing must not touch it.
        let foreign = home.appendingPathComponent("somewhere-real")
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("keep.txt"))

        let link = home.appendingPathComponent("dot-codex")
        try fm.createSymbolicLink(at: link, withDestinationURL: foreign)

        AccountMigration.healDanglingOriginSymlink(link: link, tool: .codex, homeURL: home)

        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == foreign.path,
            "a live symlink must never be repointed")
        #expect(fm.fileExists(atPath: foreign.appendingPathComponent("keep.txt").path))
    }

    @Test("a real directory is never replaced by a symlink")
    func leavesRealDirectoryAlone() throws {
        let fm = FileManager.default
        let home = tmpHome()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let real = home.appendingPathComponent("dot-claude")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: real.appendingPathComponent("settings.json"))

        AccountMigration.healDanglingOriginSymlink(link: real, tool: .claude, homeURL: home)

        #expect((try? fm.destinationOfSymbolicLink(atPath: real.path)) == nil,
            "a real directory must not be turned into a symlink")
        #expect(fm.fileExists(atPath: real.appendingPathComponent("settings.json").path))
    }

    @Test("a missing path is left missing — healing never creates a link that wasn't there")
    func leavesMissingPathAlone() throws {
        let fm = FileManager.default
        let home = tmpHome()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let absent = home.appendingPathComponent("dot-claude")

        AccountMigration.healDanglingOriginSymlink(link: absent, tool: .claude, homeURL: home)

        #expect(!fm.fileExists(atPath: absent.path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: absent.path)) == nil)
    }

    @Test("healing is idempotent — a second pass leaves the repaired link untouched")
    func idempotent() throws {
        let fm = FileManager.default
        let home = tmpHome()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let link = home.appendingPathComponent("dot-gemini")
        try fm.createSymbolicLink(
            at: link, withDestinationURL: home.appendingPathComponent("gone/gemini"))

        AccountMigration.healDanglingOriginSymlink(link: link, tool: .gemini, homeURL: home)
        let afterFirst = try fm.destinationOfSymbolicLink(atPath: link.path)
        AccountMigration.healDanglingOriginSymlink(link: link, tool: .gemini, homeURL: home)

        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == afterFirst)
    }
}
