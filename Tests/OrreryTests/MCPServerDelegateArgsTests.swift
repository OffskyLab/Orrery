import Testing
@testable import OrreryCore

@Suite("MCPServer.delegateArgs")
struct MCPServerDelegateArgsTests {

    @Test("environment argument maps to --account, not the removed -e flag")
    func environmentMapsToAccountFlag() {
        let args = MCPServer.delegateArgs(prompt: "say ok", arguments: ["environment": "work"])
        #expect(args.contains("--account"))
        #expect(args.contains("work"))
        #expect(!args.contains("-e"))
    }

    @Test("no environment argument omits the account flag entirely")
    func noEnvironmentOmitsAccountFlag() {
        let args = MCPServer.delegateArgs(prompt: "say ok", arguments: [:])
        #expect(args == ["orrery-bin", "delegate", "say ok"])
    }
}
