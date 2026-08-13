import Foundation
import OrreryCore

/// Entry point the binary calls at startup to wire concrete
/// `ToolAccountManaging` implementations into `OrreryCore.AccountDirectoryRuntime`.
public enum OrreryAccountKitRuntime {
    public static func register() {
        AccountDirectoryRuntime.makeManager = { tool in
            switch tool {
            case .claude: return ClaudeAdapter()
            case .codex: return CodexAdapter()
            case .gemini: return GeminiAdapter()
            }
        }
    }
}
