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

    @Test("phantom loop materializes credentials before each claude launch")
    func phantomLoopMaterializes() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("orrery-bin _materialize claude"))
        // The materialize step must run before claude is launched so the
        // pinned account's credentials are in place.
        guard let materialize = script.range(of: "orrery-bin _materialize claude"),
              let launch = script.range(of: "command claude \"${_phantom_args[@]}\"")
        else {
            Issue.record("generated script missing the materialize call or the claude launch")
            return
        }
        #expect(materialize.lowerBound < launch.lowerBound)
    }
}
