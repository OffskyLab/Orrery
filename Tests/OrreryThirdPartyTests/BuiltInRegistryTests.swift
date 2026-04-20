import Testing
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("BuiltInRegistry")
struct BuiltInRegistryTests {
    @Test("lookup orrery-statusline succeeds")
    func lookupCCStatusline() throws {
        let reg = BuiltInRegistry()
        let pkg = try reg.lookup("orrery-statusline")
        #expect(pkg.id == "orrery-statusline")
        #expect(pkg.steps.count == 3)
    }

    @Test("lookup unknown throws packageNotFound")
    func unknownThrows() throws {
        let reg = BuiltInRegistry()
        #expect(throws: ThirdPartyError.self) {
            _ = try reg.lookup("does-not-exist")
        }
    }

    @Test("listAvailable contains orrery-statusline")
    func lists() {
        let reg = BuiltInRegistry()
        #expect(reg.listAvailable().contains("orrery-statusline"))
    }
}
