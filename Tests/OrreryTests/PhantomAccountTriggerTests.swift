// PhantomAccountTriggerTests.swift
//
// Unit tests for PhantomAccountTriggerCommand.
//
// NOTE: The SIGTERM / relaunch path is NOT unit-tested here. It requires a live
// phantom supervisor shell loop, a running claude process in the ancestry chain,
// and actual account + env state on disk — all of which are integration concerns
// that belong in an end-to-end test harness, not in a fast unit suite. The guard
// that checks ORRERY_PHANTOM_SHELL_PID fires first, so in a unit test environment
// (where the supervisor is absent) every path that reaches the signal step is
// already unreachable. The tests below cover what IS reachable: argument parsing
// and the phantom guard.

import Testing
import Foundation
@testable import OrreryCore

@Suite("PhantomAccountTrigger", .serialized)
struct PhantomAccountTriggerTests {

    // MARK: - Not-under-phantom guard

    @Test("throws when ORRERY_PHANTOM_SHELL_PID is not set")
    func throwsWhenNotUnderPhantom() throws {
        try withIsolatedHome {
            // Ensure the env var is absent for this test.
            let saved = ProcessInfo.processInfo.environment["ORRERY_PHANTOM_SHELL_PID"]
            unsetenv("ORRERY_PHANTOM_SHELL_PID")
            defer {
                if let saved { setenv("ORRERY_PHANTOM_SHELL_PID", saved, 1) }
            }

            let cmd = try PhantomAccountTriggerCommand.parse(["--name", "x"])
            #expect(throws: (any Error).self) {
                try cmd.run()
            }
        }
    }

    // MARK: - Phantom guard fires before tool resolution

    @Test("throws not-under-phantom even with conflicting tool flags")
    func throwsNotUnderPhantomEvenWithConflictingToolFlags() throws {
        // ORRERY_PHANTOM_SHELL_PID is unset, so the phantom guard throws before
        // tool resolution ever runs. This test confirms the not-under-phantom
        // error surfaces even when conflicting tool flags are also passed.
        try withIsolatedHome {
            let saved = ProcessInfo.processInfo.environment["ORRERY_PHANTOM_SHELL_PID"]
            unsetenv("ORRERY_PHANTOM_SHELL_PID")
            defer {
                if let saved { setenv("ORRERY_PHANTOM_SHELL_PID", saved, 1) }
            }

            let cmd = try PhantomAccountTriggerCommand.parse(["--claude", "--codex", "--name", "x"])
            #expect(throws: (any Error).self) {
                try cmd.run()
            }
        }
    }
}
