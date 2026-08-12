import Foundation
import Testing
@testable import OrreryCore

@Suite("AccountLoginHooks")
struct AccountLoginHooksTests {

    @Test("does nothing when no on-login script is present")
    func noScriptIsNoop() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            // Should not throw / hang even though no script exists.
            AccountLoginHooks.fire(account: acct, accountStore: acctStore)
            #expect(!FileManager.default.fileExists(atPath: AccountLoginHooks.onLoginScriptURL.path))
        }
    }

    @Test("runs the on-login script with account info in the environment")
    func runsScriptWithEnv() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            var acct = Account(tool: .claude, displayName: "alice")
            acct.email = "alice@example.com"
            acct.plan = "pro"
            try acctStore.save(acct)

            let markerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("orrery-hook-marker-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: markerURL) }

            let scriptURL = AccountLoginHooks.onLoginScriptURL
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let script = """
            #!/bin/sh
            printf '%s|%s|%s|%s|%s|%s' \
              "$ORRERY_HOOK_EVENT" "$ORRERY_ACCOUNT_ID" "$ORRERY_ACCOUNT_NAME" \
              "$ORRERY_ACCOUNT_TOOL" "$ORRERY_ACCOUNT_EMAIL" "$ORRERY_ACCOUNT_PLAN" > "\(markerURL.path)"
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            AccountLoginHooks.fire(account: acct, accountStore: acctStore)

            let marker = try String(contentsOf: markerURL, encoding: .utf8)
            #expect(marker == "login|\(acct.id)|alice|claude|alice@example.com|pro")
        }
    }

    @Test("does not run a script that exists but isn't executable")
    func nonExecutableScriptIsSkipped() throws {
        try withIsolatedHome {
            let acctStore = AccountStore.default
            let acct = Account(tool: .claude, displayName: "alice")
            try acctStore.save(acct)

            let scriptURL = AccountLoginHooks.onLoginScriptURL
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "#!/bin/sh\nexit 1\n".write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptURL.path)

            // Should not throw despite the script being unusable.
            AccountLoginHooks.fire(account: acct, accountStore: acctStore)
        }
    }
}
