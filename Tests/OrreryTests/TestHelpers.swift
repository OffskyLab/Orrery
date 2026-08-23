import Testing
import Foundation
@testable import OrreryCore
import OrreryAccountKit

/// Registers the real `ClaudeAdapter`/`CodexAdapter` into `AccountDirectoryRuntime`,
/// mirroring what `orrery-bin`'s `main.swift` does at startup. OrreryCore's own
/// command tests (PinCommand, AccountDirLookupCommand, PrepareClaudeLaunchCommand,
/// …) exercise real account-dir symlinking through the
/// registry, so it must be populated before they run. Idempotent — cheap to
/// call from every test.
private let registerAccountKitOnce: Void = {
    OrreryAccountKitRuntime.register()
}()

/// The generated shell integration script ends with a bare `_orrery_init`
/// invocation so a normal `. activate.sh` self-bootstraps. Any test that
/// sources this script in a real shell subprocess MUST strip that invocation
/// before embedding the script, rather than relying on a later stub
/// redefinition (e.g. a `command() { ... }` override defined further down in
/// the same probe string) to intercept it: the script's text executes
/// top-to-bottom as it is interpreted, and the invocation is the LAST line —
/// so it runs immediately, before any later stub in the same probe ever
/// takes effect.
///
/// `_orrery_init` shells out to the real `orrery-bin` found on `$PATH` (the
/// developer's installed binary, not whatever this test run just built) to
/// self-update, restore pinned accounts, and link the memory directory. Left
/// unstripped, a version-stamp mismatch makes it run the REAL `orrery-bin
/// setup`, rewriting the developer's actual `~/.zshrc`/`~/.bashrc`, and
/// `_link-memory` can dangle the developer's real Claude memory symlink even
/// when `ORRERY_HOME` is otherwise isolated — both confirmed incidents.
/// To check nothing has regressed, pair up the shell spawns with the strips:
///
///     grep -c 'Process()'        Tests/OrreryTests/<file>.swift
///     grep -c 'scriptForProbe()' Tests/OrreryTests/<file>.swift
///
/// in every file that both spawns a shell and mentions
/// `ShellFunctionGenerator`. Each `Process()` that runs the script needs a strip
/// feeding it. A bare `ShellFunctionGenerator.generate()` is fine on its own —
/// inspecting the text is harmless; it is only executing it that bites.
///
/// Three confirmed incidents so far, all the same shape — isolation honoured
/// for the value, ignored for the destination: a dangled memory symlink, a
/// self-update that ran the *installed* binary rather than the built one, and a
/// `source` block written into the developer's real `~/.zshrc` pointing at a
/// temp directory that no longer existed.
func generatedShellScriptWithoutInit() -> String {
    let script = ShellFunctionGenerator.generate()
    let trailer = "\n_orrery_init"
    guard script.hasSuffix(trailer) else {
        Issue.record("generated script no longer ends with _orrery_init; update this probe-safety strip")
        return script
    }
    return String(script.dropLast(trailer.count))
}

func ensureAccountKitRegistered() {
    _ = registerAccountKitOnce
}

/// Delete any per-account claude Keychain items for accounts under `home`.
/// The macOS login Keychain is GLOBAL — `ORRERY_HOME` does not isolate it — so a
/// test that creates/copies a claude credential leaves a stray
/// `Claude Code-orrery-*` item in the developer's real login keychain unless it is
/// swept. Deletes by service name (matches regardless of the account field).
/// No-op off macOS.
func sweepClaudeKeychain(home: URL) {
    #if os(macOS)
    for acct in (try? AccountStore(homeURL: home).list(tool: .claude)) ?? [] {
        // Delete BOTH the deterministic per-account service (what
        // storePassword/copyKeychainItem use — even when metadata.keychainItem
        // was never persisted) and any explicit keychainItem, by service name.
        for service in Set([ClaudeKeychain.serviceName(forOrreryAccount: acct.id),
                            acct.keychainItem].compactMap { $0 }.filter { !$0.isEmpty }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["delete-generic-password", "-s", service]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
    #endif
}

/// Process-global lock serializing every test that mutates the global ORRERY_HOME
/// env var. swift-testing's `.serialized` only serializes within a single suite;
/// this lock serializes across ALL suites that touch ORRERY_HOME.
private let orreryHomeLock = NSLock()

/// Runs `body` with `ORRERY_HOME` pointed at a fresh temp directory.
/// Holds a process-global lock for the duration so concurrent suites cannot race.
/// Restores the previous ORRERY_HOME and deletes the temp dir afterwards.
///
/// `ORRERY_ACTIVE_ENV` / `CLAUDE_CONFIG_DIR` are scrubbed for the duration too:
/// a dev running the suite from a shell that is "in" a sandbox (or has just
/// run `orrery use` for claude) would otherwise leak that state into commands
/// like `orrery show`, which read both from the process environment. Restored
/// afterwards.
func withIsolatedHome(_ body: () throws -> Void) rethrows {
    ensureAccountKitRegistered()
    orreryHomeLock.lock()
    defer { orreryHomeLock.unlock() }

    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("orrery-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let savedHome = ProcessInfo.processInfo.environment["ORRERY_HOME"]
    let savedActiveEnv = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
    let savedClaudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    // ORRERY_USER_HOME is redirected too: `Tool.defaultConfigDir` (and other
    // home-relative paths) resolve via `userHomeURL()`, which honors it. Without
    // this a test that triggers origin-takeover code would symlink/write into the
    // developer's real ~/.claude even though ORRERY_HOME was isolated. We use a
    // dedicated var, NOT $HOME — setting $HOME breaks macOS Keychain resolution.
    let savedUserHome = ProcessInfo.processInfo.environment["ORRERY_USER_HOME"]
    setenv("ORRERY_HOME", tmpDir.path, 1)
    setenv("ORRERY_USER_HOME", tmpDir.path, 1)
    unsetenv("ORRERY_ACTIVE_ENV")
    unsetenv("CLAUDE_CONFIG_DIR")
    defer {
        // Sweep any claude Keychain items the body created (global keychain is not
        // isolated by ORRERY_HOME). Runs before the temp dir is removed.
        sweepClaudeKeychain(home: tmpDir)
        if let savedHome {
            setenv("ORRERY_HOME", savedHome, 1)
        } else {
            unsetenv("ORRERY_HOME")
        }
        if let savedUserHome {
            setenv("ORRERY_USER_HOME", savedUserHome, 1)
        } else {
            unsetenv("ORRERY_USER_HOME")
        }
        if let savedActiveEnv {
            setenv("ORRERY_ACTIVE_ENV", savedActiveEnv, 1)
        } else {
            unsetenv("ORRERY_ACTIVE_ENV")
        }
        if let savedClaudeConfigDir {
            setenv("CLAUDE_CONFIG_DIR", savedClaudeConfigDir, 1)
        } else {
            unsetenv("CLAUDE_CONFIG_DIR")
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    try body()
}

/// Process-global lock serializing every test that mutates the real process
/// environment directly via `setenv`/`unsetenv` (as opposed to `ORRERY_HOME`,
/// covered by `orreryHomeLock` above). `setenv`/`unsetenv`/`getenv` are not
/// thread-safe against each other in the C runtime — concurrent calls from
/// different swift-testing suites (which run in parallel by default) can
/// corrupt or drop updates to the shared `environ` table, not just race on
/// individual key values. Any test that calls `setenv`/`unsetenv` on the
/// real process environment (outside of `withIsolatedHome`) must hold this
/// lock for the duration.
private let realEnvironmentLock = NSLock()

func withRealEnvironmentLock(_ body: () throws -> Void) rethrows {
    realEnvironmentLock.lock()
    defer { realEnvironmentLock.unlock() }
    try body()
}
