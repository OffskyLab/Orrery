import Testing
import Foundation
@testable import OrreryCore

// MARK: - ToolSetup.applyRealEnvironment (execvp leak prevention)

/// `execLoginIfNeeded` swaps into a login shell via `execvp`, which inherits
/// this process's *actual* environment — not the intermediate `env`
/// dictionary built along the way. A key merely absent from that dictionary
/// can still be present in the real environment (inherited from the parent
/// shell, e.g. an outer supervisor) and leak into the child unchanged unless
/// it is also `unsetenv`'d.
///
/// These tests exercise `ToolSetup.applyRealEnvironment` — the exact
/// setenv/unsetenv routine `execLoginIfNeeded` performs immediately before
/// `execvp` — against this process's real environment, then spawn a real
/// child via `Process` (not `execvp`, so the test process survives) fed a
/// freshly read snapshot of that same real environment. This proves the
/// leak is closed in the environment that actually reaches the child, not
/// just in an intermediate dictionary.
@Suite("ToolSetup.applyRealEnvironment", .serialized)
struct ToolSetupApplyRealEnvironmentTests {

    /// Spawns `/usr/bin/env` with a *freshly read* `ProcessInfo.processInfo.environment`
    /// snapshot and returns its printed environment.
    ///
    /// Note: `Process`/`environment == nil` does NOT reliably pick up
    /// `setenv`/`unsetenv` calls made after the `Process` machinery first
    /// touches the environment (verified empirically — Foundation appears
    /// to cache the inherited-environment snapshot rather than reading the
    /// live `environ` table at spawn time). `ProcessInfo.processInfo.environment`,
    /// by contrast, re-reads the real environment on every access (also
    /// verified empirically via `getenv`), so explicitly passing a
    /// just-read snapshot here — rather than relying on nil-inheritance —
    /// is what actually proves the *real* process environment (the one
    /// `execvp` reads) reflects the `unsetenv` calls under test.
    private func childEnvironment() throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var result: [String: String] = [:]
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            guard let eq = line.firstIndex(of: "=") else { continue }
            result[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        return result
    }

    @Test("unsetenv removes the stripped keys from the real environment that reaches the child")
    func stripsKeysFromRealChildEnvironment() throws {
        try withRealEnvironmentLock {
            let keys = ToolSetup.strippedExecEnvKeys
            let saved = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
            defer {
                for (key, value) in saved {
                    if let value { setenv(key, value, 1) } else { unsetenv(key) }
                }
            }

            // Simulate the leak precondition: these keys are present in the
            // *real* environment (as if inherited from an outer supervisor's
            // shell), but absent from the `env` dictionary being applied —
            // mirroring `execLoginIfNeeded`'s state right before its
            // `execvp` call.
            for key in keys {
                setenv(key, "leaked-value", 1)
            }

            let env: [String: String] = ["ORRERY_TOOL_SETUP_MARKER": "present"]
            ToolSetup.applyRealEnvironment(env)

            let childEnv = try childEnvironment()
            for key in keys {
                #expect(childEnv[key] == nil, "expected \(key) to be absent from the real child environment")
            }
            #expect(childEnv["ORRERY_TOOL_SETUP_MARKER"] == "present")
        }
    }

    @Test("strippedExecEnvKeys matches the removeValue(forKey:) list in execLoginIfNeeded")
    func strippedKeysMatchExpectedSet() {
        let expected: Set<String> = [
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
            "ANTHROPIC_API_KEY", "ORRERY_PHANTOM_ID",
        ]
        #expect(Set(ToolSetup.strippedExecEnvKeys) == expected)
    }
}
