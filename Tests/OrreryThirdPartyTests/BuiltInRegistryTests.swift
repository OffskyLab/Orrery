import Testing
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("BuiltInRegistry")
struct BuiltInRegistryTests {
    @Test("lookup statusline succeeds")
    func lookupCCStatusline() throws {
        let reg = BuiltInRegistry()
        let pkg = try reg.lookup("statusline")
        #expect(pkg.id == "statusline")
        #expect(pkg.steps.count == 2)
    }

    @Test("lookup unknown throws packageNotFound")
    func unknownThrows() throws {
        let reg = BuiltInRegistry()
        #expect(throws: ThirdPartyError.self) {
            _ = try reg.lookup("does-not-exist")
        }
    }

    @Test("listAvailable contains statusline")
    func lists() {
        let reg = BuiltInRegistry()
        #expect(reg.listAvailable().contains("statusline"))
    }

    @Test("legacy id orrery-statusline still resolves but is hidden from listAvailable")
    func legacyAlias() throws {
        let reg = BuiltInRegistry()
        let pkg = try reg.lookup("orrery-statusline")
        #expect(pkg.id == "statusline")
        #expect(reg.listAvailable().contains("orrery-statusline") == false)
    }
}
