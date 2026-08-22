import Testing
import Foundation
@testable import OrreryCore

@Suite("SetupCommand")
struct SetupCommandTests {

    /// Regression test for a real incident: `rcFile(for:)` used to resolve via
    /// `FileManager.default.homeDirectoryForCurrentUser` directly, ignoring
    /// `ORRERY_USER_HOME` — the override `withIsolatedHome()` sets so tests never
    /// touch the developer's real home. Since `withIsolatedHome` deliberately
    /// doesn't touch real `$HOME` (that breaks Keychain resolution), any test
    /// that called `rcFile(for:)` inside it silently wrote to the developer's
    /// real `~/.zshrc` / `~/.bashrc`. `rcFile(for:)` must honor the same
    /// override `Tool.defaultConfigDir` and `activateFile()` already do.
    @Test("rcFile(for:) honors ORRERY_USER_HOME, does not resolve to the real home")
    func rcFileHonorsUserHomeOverride() throws {
        try withIsolatedHome {
            let userHome = ProcessInfo.processInfo.environment["ORRERY_USER_HOME"] ?? ""
            #expect(!userHome.isEmpty)
            #expect(SetupCommand.rcFile(for: "zsh").path == "\(userHome)/.zshrc")
            #expect(SetupCommand.rcFile(for: "bash").path == "\(userHome)/.bashrc")
        }
    }

    // MARK: - installShellIntegration writes the eager-source shape

    /// Regression test for a real incident: the previous "lazy bootstrap" shape
    /// only ever defined `orrery()` in the rc file. `claude()`/`gemini()` are
    /// defined solely inside `activate.sh`, which that stub only sources once
    /// `orrery` itself has been invoked at least once in the shell session — so
    /// a brand-new shell where the user runs bare `claude` before ever running
    /// `orrery` got the raw, unwrapped binary, silently bypassing phantom
    /// supervision entirely. Sourcing `activate.sh` directly and unconditionally
    /// closes that gap: every function activate.sh defines is available from
    /// the first prompt, with no bootstrap trigger required.
    @Test("writes an eager, unconditional source of activate.sh when rc is fresh")
    func appendsWhenMissing() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        try "# existing content\n".write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/tmp/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        #expect(content.contains("# orrery shell integration (source)"))
        #expect(content.contains(#"if [ -f "/tmp/activate.sh" ]; then"#))
        #expect(content.contains(#"source "/tmp/activate.sh""#))
        #expect(content.contains("fi"))
        #expect(content.contains("# existing content"))
        // The old lazy-bootstrap shape must not appear at all.
        #expect(!content.contains("(lazy bootstrap)"))
        #expect(!content.contains("orrery() {"))
    }

    @Test("running setup twice leaves exactly one block")
    func idempotent() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        try "# existing content\n".write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/tmp/activate.sh")
        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/tmp/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        let stubCount = content.components(separatedBy: "# orrery shell integration (source)").count - 1
        #expect(stubCount == 1)
        // Only one `if [ -f ... ]; then` guard, not two.
        let guardCount = content.components(separatedBy: "if [ -f \"/tmp/activate.sh\" ]; then").count - 1
        #expect(guardCount == 1)
    }

    @Test("migrates the legacy lazy-bootstrap stub (orrery() only) to the eager-source shape")
    func migratesLazyBootstrapStub() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        let legacy = """
        # existing content

        # orrery shell integration (lazy bootstrap)
        orrery() {
          source "/old/path/activate.sh"
          orrery "$@"
        }

        export FOO=bar
        """
        try legacy.write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/new/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        // Old shape is fully gone — not just the marker, the whole function body.
        #expect(!content.contains("(lazy bootstrap)"))
        #expect(!content.contains("orrery() {"))
        #expect(!content.contains(#"source "/old/path/activate.sh""#))
        // New shape is present, pointed at the new path.
        #expect(content.contains("# orrery shell integration (source)"))
        #expect(content.contains(#"source "/new/activate.sh""#))
        // Unrelated content survives.
        #expect(content.contains("# existing content"))
        #expect(content.contains("export FOO=bar"))
    }

    @Test("migrates legacy `source …/activate.sh` line to the eager-source shape")
    func migratesLegacySourceLine() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        let legacy = """
        # existing content

        # orrery shell integration
        source "/old/path/activate.sh"

        export FOO=bar
        """
        try legacy.write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/new/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        #expect(!content.contains(#"source "/old/path/activate.sh""#))
        #expect(content.contains("# orrery shell integration (source)"))
        #expect(content.contains(#"source "/new/activate.sh""#))
        #expect(content.contains("# existing content"))
        #expect(content.contains("export FOO=bar"))
    }

    @Test("migrates legacy `eval \"$(orrery setup)\"` line to the eager-source shape")
    func migratesLegacyEvalLine() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        let legacy = #"""
        # existing content
        eval "$(orrery setup)"
        export FOO=bar
        """#
        try legacy.write(to: tmpFile, atomically: true, encoding: .utf8)

        SetupCommand.installShellIntegration(to: tmpFile, activatePath: "/new/activate.sh")

        let content = try String(contentsOf: tmpFile, encoding: .utf8)
        #expect(!content.contains(#"eval "$(orrery setup)""#))
        #expect(content.contains("# orrery shell integration (source)"))
        #expect(content.contains("export FOO=bar"))
    }

    // MARK: - stripOrreryBlocks / containsOrreryBlock recognize the new shape

    /// `UninstallCommand` never hardcodes any rc-file shape itself — it removes
    /// orrery's integration purely by calling `containsOrreryBlock` then
    /// `stripOrreryBlocks` on the rc file's contents (see
    /// `UninstallCommand.swift`, step 3). So proving these two functions
    /// recognize and fully remove the new eager-source shape IS the proof that
    /// `orrery uninstall` cleans it up correctly — no separate
    /// `UninstallCommandTests` exercise of the full, destructive `run()` method
    /// (which deletes the running binary and touches system daemons) is needed
    /// or safe to write.
    @Test("containsOrreryBlock recognizes the eager-source shape")
    func containsOrreryBlockRecognizesEagerSource() {
        let content = """
        # existing content

        # orrery shell integration (source)
        if [ -f "/some/activate.sh" ]; then
          source "/some/activate.sh"
        fi
        """
        #expect(SetupCommand.containsOrreryBlock(content))
    }

    @Test("stripOrreryBlocks fully removes the eager-source shape, preserving unrelated content — proves orrery uninstall cleans it up")
    func stripOrreryBlocksRemovesEagerSource() {
        let content = """
        # existing content

        # orrery shell integration (source)
        if [ -f "/some/activate.sh" ]; then
          source "/some/activate.sh"
        fi

        export FOO=bar
        """
        let stripped = SetupCommand.stripOrreryBlocks(content)
        #expect(!stripped.contains("# orrery shell integration"))
        #expect(!stripped.contains("activate.sh"))
        #expect(!SetupCommand.containsOrreryBlock(stripped))
        #expect(stripped.contains("# existing content"))
        #expect(stripped.contains("export FOO=bar"))
    }

    @Test("stripOrreryBlocks removes the block but stops exactly at the closing `fi`, leaving what follows untouched")
    func stripOrreryBlocksStopsAtClosingFi() {
        let content = """
        # orrery shell integration (source)
        if [ -f "/some/activate.sh" ]; then
          source "/some/activate.sh"
        fi
        export AFTER=kept
        """
        let stripped = SetupCommand.stripOrreryBlocks(content)
        // The block itself must actually be gone — not merely "AFTER" surviving
        // by accident because nothing was recognized/removed at all.
        #expect(!stripped.contains("# orrery shell integration"))
        #expect(!stripped.contains("activate.sh"))
        // What comes after the closing `fi` must be untouched.
        #expect(stripped.contains("export AFTER=kept"))
    }

    // MARK: - End-to-end: claude/gemini/orrery are all functions from the first prompt

    /// THE regression test for the actual reported bug: on a genuinely fresh
    /// shell, `claude` resolved to the raw binary on PATH (not a shell
    /// function), because activate.sh — which is where `claude()`/`gemini()`
    /// are defined — was never sourced until `orrery` had been invoked at
    /// least once. `orrery phantom` then correctly, but unhelpfully, reported
    /// "no supervised session found": `_phantom-begin` was never even called,
    /// because `claude()` didn't exist to call it from.
    ///
    /// This sources the exact rc-stub `installShellIntegration` writes, in a
    /// REAL bash/zsh process, and asserts all three functions are defined
    /// immediately — without ever invoking `orrery` first, which is exactly
    /// what a brand-new terminal window does before the user types anything.
    @Test("claude, gemini, and orrery are all functions immediately after sourcing the rc stub — bash")
    func allFunctionsDefinedImmediatelyBash() throws {
        try assertAllFunctionsDefinedImmediately(shell: "bash")
    }

    @Test("claude, gemini, and orrery are all functions immediately after sourcing the rc stub — zsh")
    func allFunctionsDefinedImmediatelyZsh() throws {
        try assertAllFunctionsDefinedImmediately(shell: "zsh")
    }

    private func assertAllFunctionsDefinedImmediately(shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/\(shell)")
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/\(shell)") else {
            return
        }

        let activateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-rc-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: activateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: activateDir) }
        let activatePath = activateDir.appendingPathComponent("activate.sh")
        // Without stripping the trailing `_orrery_init` call, sourcing this
        // file below shells out to the developer's real, globally-installed
        // `orrery-bin` (not anything this test run built) — see
        // `generatedShellScriptWithoutInit()` for the confirmed incidents
        // this caused. This test only needs `claude`/`gemini`/`orrery` to be
        // defined as functions, which sourcing the script already does
        // before `_orrery_init` is ever reached.
        try generatedShellScriptWithoutInit().write(to: activatePath, atomically: true, encoding: .utf8)

        let rcFile = activateDir.appendingPathComponent("rc")
        SetupCommand.installShellIntegration(to: rcFile, activatePath: activatePath.path)
        let rcStub = try String(contentsOf: rcFile, encoding: .utf8)

        let probe = """
        \(rcStub)

        for fn in claude gemini orrery; do
          if command -v "$fn" >/dev/null 2>&1; then
            type "$fn" 2>&1 | head -1
          else
            echo "$fn: NOT FOUND"
          fi
        done
        """

        var env = ProcessInfo.processInfo.environment
        env["ORRERY_HOME"] = activateDir.appendingPathComponent("orrery-home").path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [shell, "-c", probe]
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(out.contains("claude is a") || out.contains("claude is a shell function"),
                "[\(shell)] expected claude to be a function, got: \(out)")
        #expect(out.contains("gemini is a") || out.contains("gemini is a shell function"),
                "[\(shell)] expected gemini to be a function, got: \(out)")
        #expect(out.contains("orrery is a") || out.contains("orrery is a shell function"),
                "[\(shell)] expected orrery to be a function, got: \(out)")
    }
}
