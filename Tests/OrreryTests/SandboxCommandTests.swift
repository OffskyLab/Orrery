import Testing
import Foundation
import ArgumentParser
@testable import OrreryCore

@Suite("SandboxCommand", .serialized)
struct SandboxCommandTests {

    @Test("setEnvStoresOnEnv: stores key-value on the active env")
    func setEnvStoresOnEnv() throws {
        try withIsolatedHome {
            let store = EnvironmentStore.default
            try store.save(OrreryEnvironment(name: "work"))

            let saved = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            setenv("ORRERY_ACTIVE_ENV", "work", 1)
            defer {
                if let saved { setenv("ORRERY_ACTIVE_ENV", saved, 1) }
                else { unsetenv("ORRERY_ACTIVE_ENV") }
            }

            try SandboxCommand.SetEnv.parse(["FOO", "bar"]).run()

            let env = try store.load(named: "work")
            #expect(env.env["FOO"] == "bar")
        }
    }

    @Test("setEnvUsesSandboxFlag: -s flag targets the named sandbox without ORRERY_ACTIVE_ENV")
    func setEnvUsesSandboxFlag() throws {
        try withIsolatedHome {
            let store = EnvironmentStore.default
            try store.save(OrreryEnvironment(name: "alt"))

            let saved = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            unsetenv("ORRERY_ACTIVE_ENV")
            defer {
                if let saved { setenv("ORRERY_ACTIVE_ENV", saved, 1) }
            }

            try SandboxCommand.SetEnv.parse(["KEY", "val", "-s", "alt"]).run()

            let env = try store.load(named: "alt")
            #expect(env.env["KEY"] == "val")
        }
    }

    @Test("setEnvRejectsOrigin: throws ValidationError when sandbox is 'origin'")
    func setEnvRejectsOrigin() throws {
        try withIsolatedHome {
            #expect(throws: ValidationError.self) {
                try SandboxCommand.SetEnv.parse(["KEY", "val", "-s", "origin"]).run()
            }
        }
    }

    @Test("unsetEnvRemovesKey: removes a previously set key from the active env")
    func unsetEnvRemovesKey() throws {
        try withIsolatedHome {
            let store = EnvironmentStore.default
            var seedEnv = OrreryEnvironment(name: "work")
            seedEnv.env["FOO"] = "bar"
            try store.save(seedEnv)

            let saved = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            setenv("ORRERY_ACTIVE_ENV", "work", 1)
            defer {
                if let saved { setenv("ORRERY_ACTIVE_ENV", saved, 1) }
                else { unsetenv("ORRERY_ACTIVE_ENV") }
            }

            try SandboxCommand.UnsetEnv.parse(["FOO"]).run()

            let env = try store.load(named: "work")
            #expect(env.env["FOO"] == nil)
        }
    }

    @Test("noActiveSandboxErrors: throws ValidationError when no sandbox is active and -s is not passed")
    func noActiveSandboxErrors() throws {
        try withIsolatedHome {
            let saved = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
            unsetenv("ORRERY_ACTIVE_ENV")
            defer {
                if let saved { setenv("ORRERY_ACTIVE_ENV", saved, 1) }
            }

            #expect(throws: ValidationError.self) {
                try SandboxCommand.SetEnv.parse(["FOO", "bar"]).run()
            }
        }
    }
}
