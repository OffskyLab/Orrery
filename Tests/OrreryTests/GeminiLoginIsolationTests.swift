import Foundation
import Testing
@testable import OrreryCore

/// `orrery add --gemini <name>` hung forever.
///
/// Two defects, stacked. `Tool.gemini.authLoginCommand` was
/// `["gemini", "auth", "login"]`, but gemini-cli has no `auth` subcommand —
/// its commands are `mcp`, `extensions`, `skills`, `hooks`, `gemma`, and a
/// default `[query..]`. So `auth login` parsed as a *prompt* and launched the
/// interactive chat UI, which sat waiting for input that the recording//spawn
/// never sent. (`Positional arguments now default to interactive mode` was
/// right there in the output, describing exactly what had happened.)
///
/// And the isolation was wrong regardless: the spawn set `GEMINI_CONFIG_DIR`,
/// which `GeminiAdapter`'s own doc comment says gemini-cli "ignores entirely —
/// it only ever reads `$HOME/.gemini`". Every other gemini path in the
/// codebase isolates via a HOME wrapper; this one had been left behind, so a
/// successful login would have written to the user's real `~/.gemini` and the
/// staging dir would have come back empty.
@Suite("gemini login isolation")
struct GeminiLoginIsolationTests {

    private func tmpDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-gemini-login-\(UUID().uuidString)")
    }

    @Test("gemini has no scriptable login subcommand — `gemini auth login` does not exist")
    func geminiHasNoAuthSubcommand() {
        #expect(Tool.gemini.authLoginCommand == nil,
            "gemini-cli authenticates on first interactive launch, like claude")
    }

    @Test("codex keeps its scriptable login subcommand")
    func codexKeepsAuthSubcommand() {
        #expect(Tool.codex.authLoginCommand == ["codex", "login"])
    }

    @Test("codex login isolates through its own config-dir env var")
    func codexUsesConfigDirEnvVar() throws {
        let staging = tmpDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let env = try AccountLoginFlow.prepareLoginEnvironment(
            tool: .codex, stagingDir: staging, base: ["HOME": "/original/home"])

        #expect(env["CODEX_HOME"] == staging.path)
        #expect(env["HOME"] == "/original/home", "codex honors CODEX_HOME; HOME must not move")
    }

    @Test("gemini login isolates by moving HOME, never by GEMINI_CONFIG_DIR")
    func geminiUsesHomeWrapper() throws {
        let fm = FileManager.default
        let staging = tmpDir()
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let env = try AccountLoginFlow.prepareLoginEnvironment(
            tool: .gemini, stagingDir: staging, base: ["HOME": "/original/home"])

        #expect(env["GEMINI_CONFIG_DIR"] == nil,
            "gemini-cli ignores this variable; setting it is what sent the login to the real ~/.gemini")

        let home = try #require(env["HOME"])
        #expect(home != "/original/home", "HOME must be redirected for isolation to work at all")

        // The wrapper's .gemini has to lead to the staging dir, because that is
        // the only path `importFrom` will look in afterwards.
        let link = URL(fileURLWithPath: home).appendingPathComponent(".gemini")
        let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
        let resolved = dest.hasPrefix("/")
            ? URL(fileURLWithPath: dest)
            : URL(fileURLWithPath: home).appendingPathComponent(dest)
        #expect(resolved.standardizedFileURL.resolvingSymlinksInPath().path
            == staging.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test("the credential gemini writes lands where importFrom looks for it")
    func credentialLandsInStagingDir() throws {
        let fm = FileManager.default
        let staging = tmpDir()
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let env = try AccountLoginFlow.prepareLoginEnvironment(
            tool: .gemini, stagingDir: staging, base: [:])
        let home = try #require(env["HOME"])

        // Simulate gemini-cli writing its credential to $HOME/.gemini/…
        let written = URL(fileURLWithPath: home)
            .appendingPathComponent(".gemini")
            .appendingPathComponent(FilesystemCredentialAdapter.credentialFileName(for: .gemini))
        try Data(#"{"access_token":"x"}"#.utf8).write(to: written)

        let expected = staging.appendingPathComponent(
            FilesystemCredentialAdapter.credentialFileName(for: .gemini))
        #expect(fm.fileExists(atPath: expected.path),
            "writing through the wrapper must land in the staging dir")
    }

    @Test("preparing twice is idempotent")
    func idempotent() throws {
        let fm = FileManager.default
        let staging = tmpDir()
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let first = try AccountLoginFlow.prepareLoginEnvironment(
            tool: .gemini, stagingDir: staging, base: [:])
        let second = try AccountLoginFlow.prepareLoginEnvironment(
            tool: .gemini, stagingDir: staging, base: [:])

        #expect(first["HOME"] == second["HOME"])
    }
}
