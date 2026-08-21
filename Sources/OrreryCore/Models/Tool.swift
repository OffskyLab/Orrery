import Foundation
import AIToolKit

public enum Tool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case gemini

    public var envVarName: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex:  return "CODEX_HOME"
        case .gemini: return "GEMINI_CONFIG_DIR"
        }
    }

    public var subdirectory: String { rawValue }

    /// The system default config directory (when not using Orrery).
    public var defaultConfigDir: URL {
        // userHomeURL() is overridable (ORRERY_USER_HOME) so tests can isolate
        // ~/.claude etc. from the developer's real home; unchanged in production.
        let home = userHomeURL()
        switch self {
        case .claude: return home.appendingPathComponent(".claude")
        case .codex:  return home.appendingPathComponent(".codex")
        case .gemini: return home.appendingPathComponent(".gemini")
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "\u{1F7E0} Anthropic Claude"
        case .codex:  return "\u{26AA} OpenAI Codex"
        case .gemini: return "\u{1F7E2} Google Gemini"
        }
    }

    /// Install command passed to `/usr/bin/env`. Shell commands use `["sh", "-c", "..."]`.
    public var installCommand: [String]? {
        switch self {
        case .claude: return ["sh", "-c", "curl -fsSL https://claude.ai/install.sh | bash"]
        case .codex:  return ["npm", "install", "-g", "@openai/codex"]
        case .gemini: return ["npm", "install", "-g", "@google/gemini-cli"]
        }
    }

    /// Human-readable install command shown in prompts and error messages.
    public var installCommandDisplay: String {
        switch self {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex:  return "npm install -g @openai/codex"
        case .gemini: return "npm install -g @google/gemini-cli"
        }
    }

    public var supportsSetup: Bool { installCommand != nil }

    /// Interactive auth login command, nil if not applicable (e.g. API key-based tools).
    public var authLoginCommand: [String]? {
        switch self {
        case .claude: return nil
        case .codex:  return ["codex", "login"]
        case .gemini: return ["gemini", "auth", "login"]
        }
    }

    /// ANSI 256-color code for this tool, matched to each tool's brand color.
    public var ansiColor: String {
        switch self {
        case .claude: return "\u{1B}[38;5;173m"  // #D7875F ≈ Claude coral orange #D97757
        case .codex:  return "\u{1B}[38;5;69m"   // #5F87FF ≈ Codex periwinkle #7090F0
        case .gemini: return "\u{1B}[38;5;35m"   // #00AF5F ≈ Gemini green #10B060 (bottom spike)
        }
    }

    /// Colored `[name]` tag for terminal display, e.g. `\u{1B}[33m[claude]\u{1B}[0m`.
    public var coloredTag: String { "\(ansiColor)[\(rawValue)]\u{1B}[0m" }

    /// Subdirectories within the tool's config dir that hold session data.
    /// These are symlinked to a shared location when `isolateSessions` is false.
    public var sessionSubdirectories: [String] {
        switch self {
        case .claude: return ["projects", "sessions", "session-env"]
        case .codex:  return ["sessions"]
        case .gemini: return ["tmp"]
        }
    }
}

extension Tool {
    /// This tool described in AIToolKit's terms.
    ///
    /// A bridge, not a replacement: nothing has been removed from the enum, so
    /// call sites can move to the registry one at a time. The enum is deleted
    /// once none of them read it.
    public var aiTool: AITool {
        AITool(
            id: rawValue,
            displayName: displayName,
            configDirectoryName: defaultConfigDir.lastPathComponent,
            configDirEnvVar: bridgedConfigDirEnvVar,
            authLoginCommand: authLoginCommand,
            installCommand: installCommand,
            sessionSubdirectories: sessionSubdirectories,
            ansiColor: ansiColor
        )
    }

    /// `envVarName` returns a string for every case, including gemini — but
    /// gemini-cli ignores `GEMINI_CONFIG_DIR` and reads only `$HOME/.gemini`.
    /// Setting it was the bug behind `orrery add --gemini` writing to the
    /// user's real config. The bridge reports `nil` rather than carrying that
    /// claim forward; the enum keeps its old value until its callers are gone.
    private var bridgedConfigDirEnvVar: String? {
        switch self {
        case .claude, .codex: return envVarName
        case .gemini:         return nil
        }
    }
}
