// PhantomAccountTriggerTests.swift
//
// Unit tests for PhantomAccountTriggerCommand.
//
// NOTE: The SIGTERM / relaunch path is NOT unit-tested here. It requires a live
// registry entry for a real supervisor pid, a running claude process in that
// supervisor's process tree, and actual account + env state on disk — all of
// which are integration concerns that belong in an end-to-end test harness,
// not in a fast unit suite. What IS reachable in a unit test environment
// (registry empty, no supervisor) is: argument parsing, tool resolution, the
// account-must-exist guard (checked before any registry/env lookup so a typo
// never tears down a session), and the not-under-phantom guard that fires
// once neither a live registry entry nor the legacy env var is present.
import Testing
import Foundation
import ArgumentParser
@testable import OrreryCore

@Suite("PhantomAccountTrigger", .serialized)
struct PhantomAccountTriggerTests {

    // MARK: - Not-under-phantom guard

    @Test("throws not-under-phantom when there is no live registry entry and no legacy env var")
    func throwsWhenNotUnderPhantom() throws {
        try withIsolatedHome {
            // The account must resolve first — otherwise this would just be
            // testing the (unrelated) account-not-found error.
            try AccountStore.default.save(Account(tool: .claude, displayName: "x"))

            let saved = ProcessInfo.processInfo.environment["ORRERY_PHANTOM_SHELL_PID"]
            unsetenv("ORRERY_PHANTOM_SHELL_PID")
            defer {
                if let saved { setenv("ORRERY_PHANTOM_SHELL_PID", saved, 1) }
            }

            let cmd = try PhantomAccountTriggerCommand.parse(["x"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }

    // MARK: - Account-not-found guard fires before any phantom/registry lookup

    @Test("throws account-not-found for an unknown account, even with no phantom state")
    func throwsAccountNotFoundBeforePhantomLookup() throws {
        try withIsolatedHome {
            let saved = ProcessInfo.processInfo.environment["ORRERY_PHANTOM_SHELL_PID"]
            unsetenv("ORRERY_PHANTOM_SHELL_PID")
            defer {
                if let saved { setenv("ORRERY_PHANTOM_SHELL_PID", saved, 1) }
            }

            // No account named "x" was ever saved in this isolated home.
            let cmd = try PhantomAccountTriggerCommand.parse(["x"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }

    // MARK: - Tool-flag resolution fires before account/phantom lookups

    @Test("throws on conflicting tool flags before any account or phantom lookup")
    func throwsOnConflictingToolFlags() throws {
        // Conflicting --claude/--codex flags fail tool resolution, which is the
        // very first thing run() does — this must throw regardless of account
        // or phantom/registry state.
        try withIsolatedHome {
            let cmd = try PhantomAccountTriggerCommand.parse(["--claude", "--codex", "x"])
            #expect(throws: ValidationError.self) {
                try cmd.run()
            }
        }
    }
}
