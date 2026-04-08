import Testing
@testable import OrbitalCore

@Suite("ShellFunctionGenerator")
struct ShellFunctionGeneratorTests {

    @Test("output contains orbital shell function definition")
    func containsOrbitalFunction() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("orbital()"))
    }

    @Test("output handles 'use' subcommand")
    func handlesUse() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_export"))
        #expect(script.contains("ORBITAL_ACTIVE_ENV"))
    }

    @Test("output handles 'deactivate' subcommand")
    func handlesDeactivate() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("deactivate"))
        #expect(script.contains("_unexport"))
        #expect(script.contains("unset ORBITAL_ACTIVE_ENV"))
    }

    @Test("output auto-activates current environment on shell start")
    func autoActivatesCurrent() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_orbital_init"))
        #expect(script.contains("current"))
    }
}
