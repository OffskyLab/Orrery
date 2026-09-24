import Foundation
import AIToolKit

/// Claude Code, described as a plugin.
///
/// This ships with orrery but is loaded through exactly the mechanism a third
/// party would use — which is what makes it evidence that the mechanism works,
/// rather than a special case that proves nothing.
struct ClaudeTool: AIToolIdentityReporting {
    let id = "claude"
    let displayName = "\u{1F7E0} Anthropic Claude"
    let configDirectoryName = ".claude"
    let configDirEnvVar: String? = "CLAUDE_CONFIG_DIR"
    let authLoginCommand: [String]? = nil
    let installCommand: [String]? = ["sh", "-c", "curl -fsSL https://claude.ai/install.sh | bash"]
    let sessionSubdirectories = ["projects", "sessions", "session-env"]
    let ansiColor = "\u{1B}[38;5;173m"
}

extension ClaudeTool {

    /// A listing: files only. Reading the credential store costs a subprocess
    /// per directory on macOS, and a listing is the case that must stay cheap —
    /// which is the whole reason this is a separate method from `showIdentity`.
    func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?] {
        configDirs.map { dir in
            let record = ClaudeIdentity.fromFiles(in: dir)
            // Empty means no login here, which is an answer. An all-nil
            // `LoginIdentity` would instead claim a login whose details are
            // unknown — a different thing, and false.
            return record.isEmpty ? nil : LoginIdentity(email: record.email, plan: record.plan)
        }
    }

    /// A detail view: the freshest answer, credential store included.
    func showIdentity(in configDir: URL) async throws -> LoginIdentity? {
        let record = ClaudeIdentity.fresh(in: configDir)
        return record.isEmpty ? nil : LoginIdentity(email: record.email, plan: record.plan)
    }
}

// A diagnostic entry point, before the protocol loop.
//
// The Keychain service name is derived here *and* in the host's
// `ClaudeKeychain`, and unlike the file reading it never shows up in an answer
// unless a real credential happens to be stored under it. So the two copies
// could disagree completely while every functional test passed — the drift
// would surface only on machines that actually have a credential, as a plan
// that silently stopped being reported.
//
// Exposing it makes that pinnable from a test against the shipped binary. It
// also gives a plugin author a way to ask what the host will look for, which is
// the kind of question that is otherwise answered by reading someone's source.
//
// Guarded, because what it exposes is: there is no Keychain off macOS, so
// `keychainService` does not exist there either. Calling it unconditionally
// compiled fine on the machine it was written on and broke the Linux build —
// which only the release workflow builds, so nothing said so until a release
// was being prepared.
#if os(macOS)
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--keychain-service" {
    print(ClaudeIdentity.keychainService(
        forConfigDir: URL(fileURLWithPath: CommandLine.arguments[2])))
    exit(0)
}
#endif

await PluginServer.serve(tool: ClaudeTool())
