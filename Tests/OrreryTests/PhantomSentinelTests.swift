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

    @Test("account sentinel carries tool+name and omits TARGET_ENV")
    func accountSentinel() throws {
        try PhantomTriggerCommand.writeSentinel(
            targetEnv: nil,
            targetAccountTool: "claude",
            targetAccountName: "work",
            sessionId: "sess-1",
            store: store
        )
        let text = try String(
            contentsOf: PhantomTriggerCommand.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains("TARGET_ACCOUNT_TOOL='claude'"))
        #expect(text.contains("TARGET_ACCOUNT_NAME='work'"))
        #expect(text.contains("SESSION_ID='sess-1'"))
        // An account-switch sentinel must NOT carry a TARGET_ENV line, or the
        // loop would also run `orrery use` and double-handle the switch.
        #expect(!text.contains("TARGET_ENV"))
    }

    @Test("env sentinel carries TARGET_ENV and omits account fields")
    func envSentinel() throws {
        try PhantomTriggerCommand.writeSentinel(
            targetEnv: "personal",
            targetAccountTool: nil,
            targetAccountName: nil,
            sessionId: nil,
            store: store
        )
        let text = try String(
            contentsOf: PhantomTriggerCommand.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains("TARGET_ENV='personal'"))
        #expect(text.contains("SESSION_ID=''"))
        #expect(!text.contains("TARGET_ACCOUNT_TOOL"))
        #expect(!text.contains("TARGET_ACCOUNT_NAME"))
    }

    @Test("account sentinel escapes single quotes in the account name")
    func accountSentinelEscaping() throws {
        try PhantomTriggerCommand.writeSentinel(
            targetEnv: nil,
            targetAccountTool: "claude",
            targetAccountName: "weird'name",
            sessionId: nil,
            store: store
        )
        let text = try String(
            contentsOf: PhantomTriggerCommand.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains(#"TARGET_ACCOUNT_NAME='weird'\''name'"#))
    }
}
