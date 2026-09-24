import Foundation
import AIToolKit

/// OpenAI Codex, described as a plugin.
///
/// The second tool to get one, and the reason it exists: the protocol was
/// designed while looking at claude, so until something else implements it,
/// "a third party could do this" is a claim with one example — and that example
/// is the one the design was fitted to.
///
/// Codex is a useful second case precisely because it is *unlike* claude. Its
/// credentials are one file rather than a platform keychain, its identity comes
/// out of a JWT rather than a JSON field, and it has an API-key mode with no
/// identity at all. None of that needed a protocol change, which is the result
/// worth having.
struct CodexTool: AIToolIdentityReporting {
    let id = "codex"
    let displayName = "\u{26AA} OpenAI Codex"
    let configDirectoryName = ".codex"
    let configDirEnvVar: String? = "CODEX_HOME"
    let authLoginCommand: [String]? = ["codex", "login"]
    let installCommand: [String]? = ["npm", "install", "-g", "@openai/codex"]
    let sessionSubdirectories = ["sessions"]
    let ansiColor = "\u{1B}[38;5;69m"

    /// A listing and a detail view read the same file here.
    ///
    /// Unlike claude, codex keeps everything in `auth.json` — there is no
    /// second, costlier source for a detail view to reach for. The two methods
    /// still exist because the *protocol* lets a tool distinguish them; a tool
    /// with one source answers both the same way and pays nothing for the
    /// distinction.
    func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?] {
        configDirs.map { CodexIdentity.read(in: $0) }
    }

    func showIdentity(in configDir: URL) async throws -> LoginIdentity? {
        CodexIdentity.read(in: configDir)
    }
}

await PluginServer.serve(tool: CodexTool())
