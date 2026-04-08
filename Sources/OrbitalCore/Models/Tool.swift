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

    /// Interactive auth command to run after installation, nil if not supported
    public var authCommand: [String]? {
        switch self {
        case .claude: return ["claude", "auth", "login"]
        case .codex:  return ["codex", "login"]
        case .gemini: return ["gemini", "login"]
        }
    }

    public var supportsSetup: Bool { authCommand != nil }
}
