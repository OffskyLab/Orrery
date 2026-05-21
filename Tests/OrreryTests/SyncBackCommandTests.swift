import Testing
import Foundation
@testable import OrreryCore

// The phantom supervisor loop's actual relaunch path is not unit-testable
// (live TTY + real claude), so these tests cover the `_syncback` command in
// isolation. `.serialized` because the tests mutate the global ORRERY_HOME.
@Suite("SyncBackCommand", .serialized)
struct SyncBackCommandTests {

    @Test("unknown tool is a no-op, not an error")
    func unknownToolIsNoOp() throws {
        try withIsolatedHome {
            var cmd = try SyncBackCommand.parse(["bogus-tool"])
            try cmd.run()  // must not throw
        }
    }

    @Test("syncback with no pinned account is a no-op")
    func noPinnedAccountIsNoOp() throws {
        try withIsolatedHome {
            var cmd = try SyncBackCommand.parse(["claude"])
            try cmd.run()  // no account pinned anywhere — must not throw
        }
    }
}
