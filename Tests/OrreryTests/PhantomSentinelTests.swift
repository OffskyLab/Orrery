import Testing
import Foundation
@testable import OrreryCore

/// Tests for the phantom sentinel, which carries a target account (tool+name)
/// for the supervisor loop to apply after claude exits. Workspace/env
/// switching (the former TARGET_SANDBOX field) was removed along with
/// `orrery enter`/`orrery exit`.
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

    @Test("account sentinel carries tool+name and session id")
    func accountSentinel() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude",
            targetAccountName: "work",
            sessionId: "sess-1",
            store: store
        )
        let text = try String(
            contentsOf: PhantomSupport.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains("TARGET_ACCOUNT_TOOL='claude'"))
        #expect(text.contains("TARGET_ACCOUNT_NAME='work'"))
        #expect(text.contains("SESSION_ID='sess-1'"))
        // The removed TARGET_SANDBOX field must never resurface.
        #expect(!text.contains("TARGET_SANDBOX"))
    }

    @Test("account sentinel handles nil session id")
    func accountSentinelNoSession() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude",
            targetAccountName: "personal",
            sessionId: nil,
            store: store
        )
        let text = try String(
            contentsOf: PhantomSupport.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains("TARGET_ACCOUNT_NAME='personal'"))
        #expect(text.contains("SESSION_ID=''"))
    }

    @Test("account sentinel escapes single quotes in the account name")
    func accountSentinelEscaping() throws {
        try PhantomSupport.writeSentinel(
            targetAccountTool: "claude",
            targetAccountName: "weird'name",
            sessionId: nil,
            store: store
        )
        let text = try String(
            contentsOf: PhantomSupport.sentinelURL(store: store), encoding: .utf8)
        #expect(text.contains(#"TARGET_ACCOUNT_NAME='weird'\''name'"#))
    }
}
