import Testing
import Foundation
@testable import OrbitalCore

@Suite("SetupCommand")
struct SetupCommandTests {

    @Test("appends init line when not present")
    func appendsWhenMissing() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        try "# existing content\n".write(to: tmpFile, atomically: true, encoding: .utf8)

        try SetupCommand.installShellIntegration(to: tmpFile)

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        #expect(content.contains(#"eval "$(orbital init)""#))
        #expect(content.contains("# existing content"))
    }

    @Test("does not append when line already present")
    func idempotent() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        let existing = "eval \"$(orbital init)\"\n"
        try existing.write(to: tmpFile, atomically: true, encoding: .utf8)

        try SetupCommand.installShellIntegration(to: tmpFile)

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        let count = content.components(separatedBy: "orbital init").count - 1
        #expect(count == 1)
    }
}
