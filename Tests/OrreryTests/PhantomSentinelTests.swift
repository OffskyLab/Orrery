import Testing
import Foundation
@testable import OrreryCore

/// Tests for the generalized phantom sentinel, which can carry EITHER a target
/// env (env-switch) OR a target account (account-switch). The supervisor loop
/// applies whichever is present after claude exits.
@Suite("PhantomSentinel")
struct PhantomSentinelTests {
    var tmpDir: URL!
    var store: EnvironmentStore!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-phantom-sentinel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = EnvironmentStore(homeURL: tmpDir)
    }

    @Test("account sentinel carries tool+name and omits TARGET_SANDBOX")
    func accountSentinel() throws {
        try PhantomSandboxTriggerCommand.writeSentinel(
            targetSandbox: nil,
            targetAccountTool: "claude",
            targetAccountName: "work",
            sessionId: "sess-1",
            store: store
        )
        let text = try String(
            contentsOf: PhantomSandboxTriggerCommand.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains("TARGET_ACCOUNT_TOOL='claude'"))
        #expect(text.contains("TARGET_ACCOUNT_NAME='work'"))
        #expect(text.contains("SESSION_ID='sess-1'"))
        // An account-switch sentinel must NOT carry a TARGET_SANDBOX line, or the
        // loop would also run `orrery sandbox use` and double-handle the switch.
        #expect(!text.contains("TARGET_SANDBOX"))
    }

    @Test("sandbox sentinel carries TARGET_SANDBOX and omits account fields")
    func envSentinel() throws {
        try PhantomSandboxTriggerCommand.writeSentinel(
            targetSandbox: "personal",
            targetAccountTool: nil,
            targetAccountName: nil,
            sessionId: nil,
            store: store
        )
        let text = try String(
            contentsOf: PhantomSandboxTriggerCommand.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains("TARGET_SANDBOX='personal'"))
        #expect(text.contains("SESSION_ID=''"))
        #expect(!text.contains("TARGET_ACCOUNT_TOOL"))
        #expect(!text.contains("TARGET_ACCOUNT_NAME"))
    }

    @Test("account sentinel escapes single quotes in the account name")
    func accountSentinelEscaping() throws {
        try PhantomSandboxTriggerCommand.writeSentinel(
            targetSandbox: nil,
            targetAccountTool: "claude",
            targetAccountName: "weird'name",
            sessionId: nil,
            store: store
        )
        let text = try String(
            contentsOf: PhantomSandboxTriggerCommand.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains(#"TARGET_ACCOUNT_NAME='weird'\''name'"#))
    }
}
