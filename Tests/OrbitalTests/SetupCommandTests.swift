import Testing
import Foundation
@testable import OrbitalCore

@Suite("SetupCommand")
struct SetupCommandTests {

    @Test("appends source line when not present")
    func appendsWhenMissing() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        try "# existing content\n".write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/tmp/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        #expect(content.contains(#"source "/tmp/activate.sh""#))
        #expect(content.contains("# existing content"))
    }

    @Test("does not append when source line already present")
    func idempotent() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        let existing = #"source "/tmp/activate.sh""# + "\n"
        try existing.write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/tmp/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        let count = content.components(separatedBy: #"source "/tmp/activate.sh""#).count - 1
        #expect(count == 1)
    }
}
