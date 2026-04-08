public enum Tool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case gemini

    public var envVarName: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex:  return "CODEX_CONFIG_DIR"
        case .gemini: return "GEMINI_CONFIG_DIR"
        }
    }

    public var subdirectory: String { rawValue }

    /// npm install command, nil if setup not supported
    public var installCommand: [String]? {
        switch self {
        case .claude: return ["npm", "install", "-g", "@anthropic-ai/claude-code"]
        case .codex:  return ["npm", "install", "-g", "@openai/codex"]
        case .gemini: return ["npm", "install", "-g", "@google/gemini-cli"]
        }
    }

    public var supportsSetup: Bool { installCommand != nil }

    /// Subdirectories within the tool's config dir that hold session data.
    /// These are symlinked to a shared location when `isolateSessions` is false.
    public var sessionSubdirectories: [String] {
        switch self {
        case .claude: return ["projects", "sessions", "session-env"]
        case .codex:  return []
        case .gemini: return []
        }
    }
}
