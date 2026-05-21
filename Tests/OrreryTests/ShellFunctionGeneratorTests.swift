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

    @Test("phantom loop syncs credentials back after claude exits, before the sentinel")
    func phantomLoopSyncsBack() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("orrery-bin _syncback claude"))
        // _syncback must run AFTER claude exits (so the live slot holds the
        // refreshed token) and BEFORE the sentinel is sourced/applied (so the
        // pin still points at the just-used account when sync-back runs).
        guard let launch = script.range(of: "command claude \"${_phantom_args[@]}\""),
              let syncback = script.range(of: "orrery-bin _syncback claude"),
              let sentinelSource = script.range(of: ". \"$_phantom_sentinel\"")
        else {
            Issue.record("generated script missing the claude launch, syncback, or sentinel source")
            return
        }
        #expect(launch.lowerBound < syncback.lowerBound)
        #expect(syncback.lowerBound < sentinelSource.lowerBound)
    }

    @Test("phantom loop applies a target account from the sentinel")
    func phantomLoopAppliesTargetAccount() {
        let script = ShellFunctionGenerator.generate()
        #expect(script.contains("TARGET_ACCOUNT_TOOL"))
        #expect(script.contains("TARGET_ACCOUNT_NAME"))
        #expect(script.contains("account use --\"$TARGET_ACCOUNT_TOOL\" --name \"$TARGET_ACCOUNT_NAME\""))
    }
}
