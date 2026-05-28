import Testing
import Foundation
import ArgumentParser
@testable import OrreryCore

// MARK: - JWT helper

private func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Build a fake JWT (3 segments) where the middle segment encodes `payload`
/// as base64url(JSON). Signature is opaque garbage — the parser only decodes
/// the payload.
private func makeJWT(payload: String) -> String {
    let header = b64url(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    let body = b64url(Data(payload.utf8))
    return "\(header).\(body).fakesig"
}

// MARK: - Account.refreshInfo

@Suite("Account.refreshInfo")
struct AccountRefreshInfoTests {

    /// Make a fresh AccountStore rooted at a per-test temp dir.
    private func makeStore() throws -> AccountStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-refresh-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AccountStore(homeURL: dir)
    }

    @Test("codex: extracts email + plan from auth.json JWT")
    func codexFromJWT() throws {
        let store = try makeStore()
        var acct = Account(tool: .codex, displayName: "work")
        try store.save(acct)

        // Seed `<poolDir>/auth.json` with a JWT whose claims encode email + plan.
        let jwt = makeJWT(
            payload: #"{"email":"foo@bar.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#
        )
        let poolDir = store.accountDir(id: acct.id, tool: .codex)
        try Data(#"{"tokens":{"id_token":"\#(jwt)"}}"#.utf8)
            .write(to: poolDir.appendingPathComponent("auth.json"))

        let changed = acct.refreshInfo(accountStore: store)
        #expect(changed)
        #expect(acct.email == "foo@bar.com")
        #expect(acct.plan == "pro")

        // Idempotent: second call must report no change.
        let changedAgain = acct.refreshInfo(accountStore: store)
        #expect(!changedAgain)
    }

    @Test("gemini: extracts email from oauth_creds.json id_token")
    func geminiFromOAuth() throws {
        let store = try makeStore()
        var acct = Account(tool: .gemini, displayName: "gpersonal")
        try store.save(acct)

        let jwt = makeJWT(payload: #"{"email":"g@example.com","sub":"42"}"#)
        let poolDir = store.accountDir(id: acct.id, tool: .gemini)
        try Data(#"{"id_token":"\#(jwt)"}"#.utf8)
            .write(to: poolDir.appendingPathComponent("oauth_creds.json"))

        let changed = acct.refreshInfo(accountStore: store)
        #expect(changed)
        #expect(acct.email == "g@example.com")
        #expect(acct.plan == nil)
    }

    @Test("claude: without credential email stays nil")
    func claudeWithoutCredential() throws {
        let store = try makeStore()
        var acct = Account(tool: .claude, displayName: "claude-no-cred")
        try store.save(acct)

        // No credential — both email and plan stay nil.
        let changed = acct.refreshInfo(accountStore: store)
        #expect(!changed)
        #expect(acct.email == nil)
        #expect(acct.plan == nil)
    }

    @Test("missing credential file: never throws, leaves fields nil")
    func missingCredentialIsSafe() throws {
        let store = try makeStore()
        var acct = Account(tool: .codex, displayName: "no-cred")
        try store.save(acct)
        // No `auth.json` in pool — refreshInfo must not throw and must not change.
        let changed = acct.refreshInfo(accountStore: store)
        #expect(!changed)
        #expect(acct.email == nil)
        #expect(acct.plan == nil)
    }
}

// MARK: - RunCommand.prepareSyncBack refresh-and-save

@Suite("RunCommand.prepareSyncBack refresh-and-save", .serialized)
struct RunCommandPrepareSyncBackInfoTests {

    @Test("claude: prepareSyncBack is a no-op (v3.1 shell-function managed)")
    func claudePrepareSyncBackIsNoOp() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default
            let acct = Account(tool: .claude, displayName: "claude-sb-noop")
            try acctStore.save(acct)
            var env = OrreryEnvironment(name: "claude-env")
            env.setAccount(acct.id, for: .claude)
            try envStore.save(env)
            // Must not throw and must not modify the account in the store.
            try RunCommand.prepareSyncBack(tool: .claude, envName: "claude-env")
            let reloaded = try acctStore.load(id: acct.id, tool: .claude)
            #expect(reloaded.email == nil)
        }
    }

    @Test("codex: prepareSyncBack populates email and plan from auth.json JWT")
    func codexSyncBackRefreshesAccountInfo() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let envStore = EnvironmentStore.default

            // 1. Create a codex account with nil email/plan in the pool.
            var acct = Account(tool: .codex, displayName: "sb-codex")
            try acctStore.save(acct)
            #expect(acct.email == nil)
            #expect(acct.plan == nil)

            // 2. Seed the pool dir with an auth.json containing a JWT with
            //    email and plan claims (mirrors the codexFromJWT fixture shape).
            let jwt = makeJWT(
                payload: #"{"email":"syncback@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#
            )
            let poolDir = acctStore.accountDir(id: acct.id, tool: .codex)
            try Data(#"{"tokens":{"id_token":"\#(jwt)"}}"#.utf8)
                .write(to: poolDir.appendingPathComponent("auth.json"))

            // 3. Create a named env that pins this account and set ORRERY_ACTIVE_ENV.
            var env = OrreryEnvironment(name: "sb-env")
            env.setAccount(acct.id, for: .codex)
            try envStore.save(env)

            // Ensure the env config dir exists (prepareMaterialize / syncBack expects
            // the dir to be present for codex's symlink adapter).
            let configDir = envStore.toolConfigDir(tool: .codex, environment: "sb-env")
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

            // 4. Call prepareSyncBack — for codex the adapter is a no-op (symlink),
            //    but the refresh-and-save that follows IS the load-bearing work.
            try RunCommand.prepareSyncBack(tool: .codex, envName: "sb-env")

            // 5. Re-load from the store and assert that email/plan are now populated.
            let reloaded = try acctStore.load(id: acct.id, tool: .codex)
            #expect(reloaded.email == "syncback@example.com")
            #expect(reloaded.plan == "pro")
        }
    }
}

// MARK: - AccountMigration.runInfoBackfillIfNeeded

@Suite("AccountMigration.runInfoBackfillIfNeeded")
struct AccountInfoBackfillTests {

    private func makeTempHome() -> (home: URL, cleanup: () -> Void) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-info-backfill-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let home = parent.appendingPathComponent(".orrery")
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: parent) }
        return (home, cleanup)
    }

    @Test("runs for Claude accounts and writes the flag (no credential → email stays nil)")
    func backfillsClaudeNoOp() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let acctStore = AccountStore(homeURL: home)

        // Pre-existing Claude account without email/plan, no credential blob.
        let acct = Account(tool: .claude, displayName: "needs-backfill")
        try acctStore.save(acct)

        // Run backfill — no credential to read, so email stays nil.
        AccountMigration.runInfoBackfillIfNeeded(homeURL: home)

        let reloaded = try acctStore.load(id: acct.id, tool: .claude)
        #expect(reloaded.email == nil)

        // Flag file written regardless.
        let flag = home.appendingPathComponent(AccountMigration.infoBackfillFlagFileName)
        #expect(FileManager.default.fileExists(atPath: flag.path))
    }

    @Test("second run is a no-op (flag already exists)")
    func secondRunNoOp() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let acctStore = AccountStore(homeURL: home)
        let acct = Account(tool: .codex, displayName: "stays-empty")
        try acctStore.save(acct)

        // Pre-create the flag.
        let flag = home.appendingPathComponent(AccountMigration.infoBackfillFlagFileName)
        try Data("v1\n".utf8).write(to: flag)

        // Add an auth.json that WOULD be backfilled in a first run.
        let jwt = makeJWT(payload: #"{"email":"should-not-show@example.com"}"#)
        let poolDir = acctStore.accountDir(id: acct.id, tool: .codex)
        try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"id_token":"\#(jwt)"}}"#.utf8)
            .write(to: poolDir.appendingPathComponent("auth.json"))

        AccountMigration.runInfoBackfillIfNeeded(homeURL: home)

        let reloaded = try acctStore.load(id: acct.id, tool: .codex)
        #expect(reloaded.email == nil)  // because backfill was skipped
    }

    @Test("fills codex email/plan from pool credentials regardless of tool")
    func backfillsCodexFromCredential() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let acctStore = AccountStore(homeURL: home)
        let acct = Account(tool: .codex, displayName: "codex-backfill")
        try acctStore.save(acct)

        let jwt = makeJWT(
            payload: #"{"email":"cx@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#
        )
        let poolDir = acctStore.accountDir(id: acct.id, tool: .codex)
        try Data(#"{"tokens":{"id_token":"\#(jwt)"}}"#.utf8)
            .write(to: poolDir.appendingPathComponent("auth.json"))

        AccountMigration.runInfoBackfillIfNeeded(homeURL: home)

        let reloaded = try acctStore.load(id: acct.id, tool: .codex)
        #expect(reloaded.email == "cx@example.com")
        #expect(reloaded.plan == "plus")
    }
}

@Suite("Account.workspace")
struct AccountWorkspaceTests {
    @Test("new Account defaults workspace to 'origin'")
    func defaultsToOrigin() {
        let acct = Account(tool: .claude, displayName: "test")
        #expect(acct.workspace == "origin")
    }

    @Test("Account decodes legacy metadata.json without workspace field as 'origin'")
    func decodesLegacyMetadata() throws {
        let legacyJSON = """
        {
          "id": "ABC-123",
          "tool": "claude",
          "displayName": "legacy",
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let acct = try decoder.decode(Account.self, from: Data(legacyJSON.utf8))
        #expect(acct.workspace == "origin")
    }

    @Test("Account round-trips workspace through Codable")
    func roundTripsWorkspace() throws {
        let acct = Account(tool: .claude, displayName: "test", workspace: "work")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(acct)

        // Sanity-check the raw JSON: catches a typo in CodingKeys that would
        // otherwise silently let the default kick in on decode.
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"workspace\":\"work\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: data)
        #expect(decoded.workspace == "work")
    }

    @Test("Account preserves explicit 'origin' through round-trip (distinct from default fallback)")
    func explicitOriginRoundTrip() throws {
        // Distinguishes 'workspace was explicitly written as origin in JSON'
        // from 'workspace was absent and defaulted to origin'.
        let acct = Account(tool: .claude, displayName: "test", workspace: "origin")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(acct)

        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"workspace\":\"origin\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: data)
        #expect(decoded.workspace == "origin")
    }
}
