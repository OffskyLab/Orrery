import Testing
@testable import OrreryThirdParty

@Suite("OrreryThirdParty bootstrap")
struct OrreryThirdPartyBootstrapTests {
    @Test("target compiles")
    func compiles() {
        // Presence of this test is enough. Real tests land with each impl task.
        #expect(Bool(true))
    }
}
