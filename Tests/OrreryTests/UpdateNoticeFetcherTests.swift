import Testing
@testable import OrreryCore

@Suite("SemanticVersion")
struct SemanticVersionTests {

    @Test("parses three-component versions")
    func parsesThreeComponent() {
        let v = SemanticVersion("2.4.0")
        #expect(v == SemanticVersion(major: 2, minor: 4, patch: 0))
    }

    @Test("strips pre-release suffix")
    func stripsSuffix() {
        #expect(SemanticVersion("2.4.0-beta") == SemanticVersion(major: 2, minor: 4, patch: 0))
        #expect(SemanticVersion("2.4.0+build.7") == SemanticVersion(major: 2, minor: 4, patch: 0))
    }

    @Test("returns nil for fewer than three components")
    func rejectsTooFewComponents() {
        #expect(SemanticVersion("2.4") == nil)
        #expect(SemanticVersion("2") == nil)
    }

    @Test("returns nil for non-numeric components")
    func rejectsNonNumeric() {
        #expect(SemanticVersion("two.four.zero") == nil)
        #expect(SemanticVersion("2.4.x") == nil)
        #expect(SemanticVersion("") == nil)
    }

    @Test("Comparable orders versions correctly")
    func comparable() {
        #expect(SemanticVersion("2.3.0")! < SemanticVersion("2.4.0")!)
        #expect(SemanticVersion("2.3.1")! > SemanticVersion("2.3.0")!)
        #expect(SemanticVersion("2.0.0")! < SemanticVersion("10.0.0")!)  // numeric, not lex
        #expect(SemanticVersion("2.4.0")! == SemanticVersion("2.4.0")!)
    }
}
