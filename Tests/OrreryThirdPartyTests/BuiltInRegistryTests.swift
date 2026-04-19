import Testing
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("BuiltInRegistry")
struct BuiltInRegistryTests {
    @Test("lookup cc-statusline succeeds")
    func lookupCCStatusline() throws {
        let reg = BuiltInRegistry()
        let pkg = try reg.lookup("cc-statusline")
        #expect(pkg.id == "cc-statusline")
        #expect(pkg.steps.count == 3)
    }

    @Test("lookup unknown throws packageNotFound")
    func unknownThrows() throws {
        let reg = BuiltInRegistry()
        #expect(throws: ThirdPartyError.self) {
            _ = try reg.lookup("does-not-exist")
        }
    }

    @Test("listAvailable contains cc-statusline")
    func lists() {
        let reg = BuiltInRegistry()
        #expect(reg.listAvailable().contains("cc-statusline"))
    }
}
