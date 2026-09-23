import Foundation
import Testing
@testable import OrreryCore

/// `orrery add --gemini <name>` produced no output at all and had to be killed.
///
/// The generated shell function routed only claude's add through the shell,
/// on the stated assumption that "codex/gemini work fine via the regular
/// orrery-bin path (their login subcommands open a browser and don't need TTY
/// foreground)". That is true of codex and false of gemini, which has no login
/// subcommand and instead opens a full TUI that puts stdin in raw mode.
///
/// Captured from a hung run, and the reason this is a shell-routing fix rather
/// than anything to do with credentials:
///
///     PID    STAT  PGID   TPGID  COMMAND
///     25907  S+    25907  25907  orrery-bin add --gemini demo-1
///     25908  T     25908  25907  node …/gemini
///
/// `orrery-bin` holds the terminal (PGID == TPGID). Swift's `Process` puts the
/// child in its own group, so gemini sat in a *background* group, took
/// SIGTTIN/SIGTTOU the moment it touched the terminal, and was stopped (`T`)
/// before it ever drew a frame. Same mechanism the claude branch was already
/// built to avoid.
@Suite("gemini add — shell routing")
struct GeminiAddShellRoutingTests {

    private var script: String { ShellFunctionGenerator.generate() }

    @Test("gemini's add runs the binary from the shell, not through Swift's Process")
    func geminiAddRunsFromShell() {
        #expect(script.contains("command gemini"),
            "gemini must be launched by the shell so it inherits the foreground process group")
    }

    @Test("gemini's add isolates via HOME, the only thing gemini-cli honors")
    func geminiAddUsesHomeWrapper() {
        #expect(script.contains(#"HOME="${_staging}-home" command gemini"#),
            "gemini-cli ignores GEMINI_CONFIG_DIR; the staging dir reaches it through a HOME wrapper")
    }

    @Test("gemini's add is bracketed by prepare and finalize, like claude's")
    func geminiAddBracketedByPrepareAndFinalize() throws {
        // Anchored on the gemini launch line rather than on the `add)` case's
        // indentation, so reformatting the generated script can't quietly turn
        // this into a test that passes by matching claude's branch instead.
        let launch = #"HOME="${_staging}-home" command gemini"#
        let launchIndex = try #require(script.range(of: launch)?.lowerBound)

        let branch = String(script[script.startIndex..<launchIndex])
            .components(separatedBy: "if [ $_is_gemini -eq 1 ]; then").last ?? ""
        let after = String(script[launchIndex...])

        // prepare has to have produced the staging dir the launch line uses…
        #expect(branch.contains(#"_staging=$(command orrery-bin _account-add-prepare"#))

        // …and finalize has to run once the login exits.
        let finalize = try #require(after.range(of: "_account-add-finalize")?.lowerBound)
        #expect(after[finalize...].hasPrefix("_account-add-finalize --staging"))
    }

    /// The first draft of this branch reused claude's hint verbatim, so a
    /// gemini add told the user to "run /exit — or just keep using Claude".
    @Test("gemini's hint is its own, not claude's")
    func geminiHintIsNotClaudes() throws {
        let launch = #"HOME="${_staging}-home" command gemini"#
        let launchIndex = try #require(script.range(of: launch)?.lowerBound)
        let branch = String(script[script.startIndex..<launchIndex])
            .components(separatedBy: "if [ $_is_gemini -eq 1 ]; then").last ?? ""

        #expect(!branch.contains("Claude"),
            "the gemini branch must not print claude's wording")
        #expect(!branch.contains("/exit"),
            "/exit is a claude command — gemini's hint must not name it")
    }

    @Test("codex is left on the plain orrery-bin path — its login needs no TTY foreground")
    func codexStillUsesBinaryPath() {
        #expect(!script.contains("command codex"),
            "codex login opens a browser and works fine spawned; routing it through the shell would be churn")
    }
}

/// The HOME wrapper the shell branch above hands to gemini has to exist before
/// gemini starts, and `_account-add-prepare` is the step that creates the
/// staging dir, so it creates the wrapper too.
@Suite("_account-add-prepare — gemini HOME wrapper")
struct GeminiPrepareWrapperTests {

    @Test("prepare builds a `<staging>-home` wrapper whose .gemini leads to the staging dir")
    func prepareCreatesWrapper() throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("orrery-login-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: staging.deletingLastPathComponent()
                .appendingPathComponent(staging.lastPathComponent + "-home"))
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        try AccountAddPrepareCommand.ensureGeminiHomeWrapper(stagingDir: staging)

        let wrapper = staging.deletingLastPathComponent()
            .appendingPathComponent(staging.lastPathComponent + "-home")
        let link = wrapper.appendingPathComponent(".gemini")
        let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
        let resolved = dest.hasPrefix("/")
            ? URL(fileURLWithPath: dest)
            : wrapper.appendingPathComponent(dest)

        #expect(resolved.standardizedFileURL.resolvingSymlinksInPath().path
            == staging.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test("creating the wrapper twice is idempotent")
    func idempotent() throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("orrery-login-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: staging.deletingLastPathComponent()
                .appendingPathComponent(staging.lastPathComponent + "-home"))
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        try AccountAddPrepareCommand.ensureGeminiHomeWrapper(stagingDir: staging)
        try AccountAddPrepareCommand.ensureGeminiHomeWrapper(stagingDir: staging)

        let wrapper = staging.deletingLastPathComponent()
            .appendingPathComponent(staging.lastPathComponent + "-home")
        #expect((try? fm.destinationOfSymbolicLink(
            atPath: wrapper.appendingPathComponent(".gemini").path)) != nil)
    }
}
