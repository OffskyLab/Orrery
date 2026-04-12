import Testing
@testable import OrreryCore

@Suite("ShellFunctionGenerator")
struct ShellFunctionGeneratorTests {

    @Test("output contains orrery shell function definition")
    func containsOrreryFunction() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("orrery()"))
    }

    @Test("output handles 'use' subcommand")
    func handlesUse() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_export"))
        #expect(script.contains("ORRERY_ACTIVE_ENV"))
    }

    @Test("output handles 'deactivate' subcommand")
    func handlesDeactivate() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("deactivate"))
        #expect(script.contains("orrery use origin"))
    }

    @Test("output auto-activates current environment on shell start")
    func autoActivatesCurrent() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("_orrery_init"))
        #expect(script.contains("current"))
    }
}
