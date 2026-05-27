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

    @Test("claude: email is populated from the pool oauthAccount snapshot")
    func claudeFromPoolSnapshot() throws {
        let store = try makeStore()
        var acct = Account(tool: .claude, displayName: "claude-work")
        try store.save(acct)

        // Write a snapshot into the pool dir (as captureFromActive would).
        let poolDir = store.accountDir(id: acct.id, tool: .claude)
        try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        let snapURL = ClaudeOAuthSnapshot.snapshotURL(poolDir: poolDir)
        try Data(#"{"emailAddress":"alice@example.com"}"#.utf8).write(to: snapURL)

        let changed = acct.refreshInfo(accountStore: store)
        #expect(changed)
        #expect(acct.email == "alice@example.com")
    }

    @Test("claude: without snapshot or credential email stays nil")
    func claudeWithoutSnapshot() throws {
        let store = try makeStore()
        var acct = Account(tool: .claude, displayName: "claude-no-snap")
        try store.save(acct)

        // No pool snapshot file and no credential — both email and plan stay nil.
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

    @Test("backfills Claude email from a referencing env's .claude.json and writes the flag")
    func backfillsClaudeEmail() throws {
        let (home, cleanup) = makeTempHome()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let envStore = EnvironmentStore(homeURL: home)
        let acctStore = AccountStore(homeURL: home)

        // Pre-existing Claude account without email/plan, no credential blob.
        let acct = Account(tool: .claude, displayName: "needs-backfill")
        try acctStore.save(acct)

        // A named env that pins this account.
        var env = OrreryEnvironment(name: "work-env")
        env.setAccount(acct.id, for: .claude)
        try envStore.save(env)

        // Drop a `.claude.json` into the env's claude tool dir.
        let claudeDir = envStore.toolConfigDir(tool: .claude, environment: "work-env")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"backfill@example.com"}}"#.utf8)
            .write(to: claudeDir.appendingPathComponent(".claude.json"))

        // Run backfill.
        AccountMigration.runInfoBackfillIfNeeded(homeURL: home)

        // Account email is now populated.
        let reloaded = try acctStore.load(id: acct.id, tool: .claude)
        #expect(reloaded.email == "backfill@example.com")

        // Flag file written.
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
