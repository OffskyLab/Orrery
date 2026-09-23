import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The first call site to actually route through a tool's own answer.
///
/// It is a *transition*: claude's plugin does not implement
/// `AIToolIdentityReporting` yet — that logic is still the `switch account.tool`
/// in this file, and moves when claude's implementation leaves this repository.
/// So the registry is preferred when it can answer and the existing
/// implementation stands in when it cannot.
///
/// A fallback is the right shape *here* and would be wrong for a capability the
/// plugin genuinely has. Falling back when the plugin could have answered would
/// make the plugin unobservable — delete it and nothing changes. Falling back
/// when the capability does not exist yet is scaffolding with a removal
/// condition: it goes when claude's plugin reports identities.
@Suite("account identity")
struct AccountIdentityTests {

    /// A tool that reports identities, answering distinctively enough that a test
    /// can tell its answer from the enum implementation's.
    private struct Reporting: AIToolIdentityReporting {
        let id: String
        let displayName = "Reporting"

        func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?] {
            configDirs.enumerated().map { i, _ in
                LoginIdentity(email: "listed-\(i)@plugin", plan: "FromPlugin")
            }
        }

        func showIdentity(in configDir: URL) async throws -> LoginIdentity? {
            LoginIdentity(email: "shown@plugin", plan: "FromPlugin")
        }
    }

    private func store(_ home: URL) -> AccountStore { AccountStore(homeURL: home) }

    private func makeHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("identity-site-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a listing asks the tool once and keeps the answers aligned")
    func listingPrefersTheTool() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let acctStore = store(home)
        let accounts = try (0..<3).map { i -> Account in
            let a = Account(tool: .claude, displayName: "acct-\(i)", workspace: "origin")
            try acctStore.save(a)
            return a
        }

        let registry = AIToolRegistry()
        try registry.register(Reporting(id: "claude"))

        let found = await AccountAuthInfo.identities(
            for: accounts, liveAccountID: nil, store: acctStore, registry: registry)

        #expect(found.count == 3)
        // Positional all the way through: the nth answer belongs to the nth
        // account, and a shifted array would still look entirely plausible.
        #expect(found[0].email == "listed-0@plugin")
        #expect(found[2].email == "listed-2@plugin")
        #expect(found[1].plan == "FromPlugin")
    }

    @Test("a detail view asks the tool for one account")
    func detailPrefersTheTool() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let acctStore = store(home)
        let account = Account(tool: .claude, displayName: "one", workspace: "origin")
        try acctStore.save(account)

        let registry = AIToolRegistry()
        try registry.register(Reporting(id: "claude"))

        let found = await AccountAuthInfo.identity(
            for: account, isLiveInThisShell: false, store: acctStore, registry: registry)

        #expect(found.email == "shown@plugin")
    }

    /// The transition's other half, and the one that is exercised in production
    /// today: nothing registered under that id reports identities, so the answer
    /// comes from the implementation that is still here.
    @Test("a tool that cannot report identities falls back to the built-in path")
    func fallsBackWhenToolCannotAnswer() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let acctStore = store(home)
        let account = Account(
            tool: .claude, displayName: "persisted",
            email: "from-metadata@example.com", plan: "Pro", workspace: "origin")
        try acctStore.save(account)

        // Registry holds a plain tool: registered, describable, no identity
        // capability — exactly claude's situation until its plugin implements one.
        let registry = AIToolRegistry()
        try registry.register(Tool.claude.aiTool)

        let found = await AccountAuthInfo.identity(
            for: account, isLiveInThisShell: false, store: acctStore, registry: registry)

        #expect(found.email == "from-metadata@example.com",
                "with no tool-side answer, the persisted account fields still show")
        #expect(found.plan == "Pro")
    }

    @Test("an unregistered tool falls back rather than failing")
    func unregisteredToolFallsBack() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let acctStore = store(home)
        let account = Account(
            tool: .claude, displayName: "orphan",
            email: "orphan@example.com", plan: nil, workspace: "origin")
        try acctStore.save(account)

        // Empty registry — a broken install, or a bootstrap that has not run.
        // A listing must still render rather than throw at the user.
        let found = await AccountAuthInfo.identity(
            for: account, isLiveInThisShell: false, store: acctStore, registry: AIToolRegistry())

        #expect(found.email == "orphan@example.com")
    }

    @Test("an empty listing asks the tool nothing and returns nothing")
    func emptyListing() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = AIToolRegistry()
        try registry.register(Reporting(id: "claude"))

        let found = await AccountAuthInfo.identities(
            for: [], liveAccountID: nil, store: store(home), registry: registry)

        #expect(found.isEmpty)
    }

    // MARK: - What absence looks like now the plugin answers

    /// The property the fallback was quietly destroying.
    ///
    /// While the host could read claude's own files, deleting `orrery-claude`
    /// changed nothing a user could see — which is indistinguishable from never
    /// having consulted the plugin at all. The bootstrap says out loud that a
    /// missing shipped plugin is a broken install; a fallback that then answers
    /// anyway contradicts it, one call site at a time.
    ///
    /// So with no tool registered, claude's identity is now whatever orrery
    /// itself recorded — its own cache — and nothing more.
    @Test("without the plugin, claude's identity is orrery's own record and nothing more")
    func absentPluginLeavesOnlyOrreryRecord() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let acctStore = store(home)
        let account = Account(
            tool: .claude, displayName: "cached",
            email: "cache@example.com", plan: "Pro", workspace: "origin")
        try acctStore.save(account)

        // A claude identity file sitting right there, which the host used to
        // read. It must now be invisible: reading it is the plugin's job.
        let accountDir = acctStore.accountDir(id: account.id, tool: .claude)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        let identity: [String: Any] = [
            "oauthAccount": ["emailAddress": "from-file@example.com", "subscriptionType": "Max"],
        ]
        try JSONSerialization.data(withJSONObject: identity)
            .write(to: accountDir.appendingPathComponent("claude-identity.json"))

        let found = await AccountAuthInfo.identity(
            for: account, isLiveInThisShell: false, store: acctStore, registry: AIToolRegistry())

        #expect(found.email == "cache@example.com",
                "the host must not be reading claude's files any more")
        #expect(found.plan == "Pro")
    }

    /// codex and gemini keep their host-side reading, because they have no
    /// plugin to hand it to yet. Removing theirs at the same time would have
    /// been a regression dressed as consistency.
    @Test("a tool with no plugin at all still reads through the host")
    func toolsWithoutPluginsAreUnaffected() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let acctStore = store(home)
        let account = Account(
            tool: .codex, displayName: "codex-acct",
            email: "codex@example.com", plan: nil, workspace: "origin")
        try acctStore.save(account)

        let found = await AccountAuthInfo.identity(
            for: account, isLiveInThisShell: false, store: acctStore, registry: AIToolRegistry())

        #expect(found.email == "codex@example.com")
    }

}
