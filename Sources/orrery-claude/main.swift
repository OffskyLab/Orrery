import Foundation
import AIToolKit

/// Claude Code, described as a plugin.
///
/// This ships with orrery but is loaded through exactly the mechanism a third
/// party would use — which is what makes it evidence that the mechanism works,
/// rather than a special case that proves nothing.
struct ClaudeTool: AITool {
    let id = "claude"
    let displayName = "\u{1F7E0} Anthropic Claude"
    let configDirectoryName = ".claude"
    let configDirEnvVar: String? = "CLAUDE_CONFIG_DIR"
    let authLoginCommand: [String]? = nil
    let installCommand: [String]? = ["sh", "-c", "curl -fsSL https://claude.ai/install.sh | bash"]
    let sessionSubdirectories = ["projects", "sessions", "session-env"]
    let ansiColor = "\u{1B}[38;5;173m"
}

PluginServer.serve(tool: ClaudeTool())
