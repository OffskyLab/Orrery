import Testing
import Foundation
@testable import OrreryCore

// The phantom supervisor loop's actual relaunch path is not unit-testable
// (live TTY + real claude), so these tests cover the `_materialize` command
// in isolation. `.serialized` because the tests mutate the global ORRERY_HOME.
@Suite("MaterializeCommand", .serialized)
struct MaterializeCommandTests {

    @Test("unknown tool is a no-op, not an error")
    func unknownToolIsNoOp() throws {
        try withIsolatedHome {
            var cmd = try MaterializeCommand.parse(["bogus-tool"])
            try cmd.run()  // must not throw
        }
    }

    @Test("materialize with no pinned account is a no-op")
    func noPinnedAccountIsNoOp() throws {
        try withIsolatedHome {
            var cmd = try MaterializeCommand.parse(["claude"])
            try cmd.run()  // no account pinned anywhere — must not throw
        }
    }
}
