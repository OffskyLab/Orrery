// swiftlint:disable type_body_length file_length
public enum L10n {
    private static var locale: AppLocale { AppLocale.current }
    private static var isChinese: Bool { locale == .zhHant }

    // MARK: - OrbitalCommand

    public enum Orbital {
        public static var abstract: String {
            isChinese
                ? "AI CLI 環境管理工具 — 管理 Claude、Codex、Gemini 帳號"
                : "AI CLI environment manager — manage accounts for Claude, Codex, Gemini"
        }
    }

    // MARK: - CreateCommand

    public enum Create {
        public static var abstract: String {
            isChinese ? "建立新的 orbital 環境" : "Create a new orbital environment"
        }
        public static var nameHelp: String {
            isChinese ? "新環境的名稱" : "Name for the new environment"
        }
        public static var descriptionHelp: String {
            isChinese ? "此環境的描述" : "Description for this environment"
        }
        public static var cloneHelp: String {
            isChinese
                ? "從現有環境複製工具與環境變數"
                : "Clone tools and env vars from an existing environment"
        }
        public static var toolHelp: String {
            isChinese
                ? "加入工具 (claude, codex, gemini)。可重複使用：--tool claude --tool codex"
                : "Add a tool (claude, codex, gemini). Repeatable: --tool claude --tool codex"
        }
        public static var isolateSessionsHelp: String {
            isChinese
                ? "隔離各環境的 session（預設為共享）"
                : "Isolate sessions per environment instead of sharing them across environments (default: shared)"
        }
        public static func alreadyExists(_ name: String) -> String {
            isChinese
                ? "環境 '\(name)' 已存在。請使用其他名稱或先執行 'orbital delete \(name)'。"
                : "Environment '\(name)' already exists. Use a different name or 'orbital delete \(name)' first."
        }
        public static var reservedName: String {
            isChinese
                ? "'default' 是保留的環境名稱，無法使用。"
                : "'default' is a reserved environment name."
        }
        public static func unknownTool(_ raw: String) -> String {
            let valid = Tool.allCases.map(\.rawValue).joined(separator: ", ")
            return isChinese
                ? "未知工具 '\(raw)'。可用工具：\(valid)"
                : "Unknown tool '\(raw)'. Valid tools: \(valid)"
        }
        public static func created(_ name: String) -> String {
            isChinese ? "已建立環境：\(name)" : "Created environment: \(name)"
        }
        public static func cloned(_ source: String) -> String {
            isChinese
                ? "已從 \(source) 複製工具與環境變數"
                : "Cloned tools and env vars from: \(source)"
        }
        public static func tools(_ list: String) -> String {
            isChinese ? "工具：\(list)" : "Tools: \(list)"
        }
        public static func sessions(_ isolated: Bool) -> String {
            isChinese
                ? "Session：\(isolated ? "隔離" : "共享")"
                : "Sessions: \(isolated ? "isolated" : "shared")"
        }
        public static func firstEnvCreated(_ name: String) -> String {
            isChinese
                ? "\n已建立第一個環境 — 自動啟用 '\(name)'。\n執行 'orbital use \(name)' 以套用到此 shell。"
                : "\nFirst environment created — activating '\(name)' automatically.\nRun 'orbital use \(name)' to apply it to this shell."
        }
        public static var wizardTitle: String {
            isChinese
                ? "選擇要加入的工具（↑↓ 移動，空白鍵切換，Enter 確認）："
                : "Select tools to add (↑↓ move, space toggle, enter confirm):"
        }
        public static var clonePrompt: String {
            isChinese
                ? "要從現有環境複製設定嗎？（↑↓ 移動，Enter 確認）："
                : "Clone config from an existing environment? (↑↓ move, enter confirm):"
        }
        public static var cloneNone: String {
            isChinese ? "不複製（全新環境）" : "Don't clone (fresh environment)"
        }
        public static func cloneFrom(_ name: String) -> String {
            isChinese ? "從 \(name) 複製" : "Clone from \(name)"
        }
        public static var defaultDescription: String {
            isChinese ? "原始環境" : "System default"
        }
        public static var sessionSharePrompt: String {
            isChinese
                ? "Session 共享設定（↑↓ 移動，Enter 確認）："
                : "Session sharing (↑↓ move, enter confirm):"
        }
        public static var sessionShareYes: String {
            isChinese
                ? "共享 session（切換帳號後可接續對話）"
                : "Share sessions (resume conversations after switching)"
        }
        public static var sessionShareNo: String {
            isChinese
                ? "隔離 session（各環境完全獨立）"
                : "Isolate sessions (fully independent per environment)"
        }
    }

    // MARK: - DeleteCommand

    public enum Delete {
        public static var abstract: String {
            isChinese ? "刪除 orbital 環境" : "Delete an orbital environment"
        }
        public static var nameHelp: String {
            isChinese ? "要刪除的環境名稱" : "Name of the environment to delete"
        }
        public static var forceHelp: String {
            isChinese ? "跳過確認提示" : "Skip confirmation prompt"
        }
        public static func confirm(_ name: String) -> String {
            isChinese
                ? "確定要刪除環境 '\(name)'？此操作無法復原。[y/N] "
                : "Delete environment '\(name)'? This cannot be undone. [y/N] "
        }
        public static var aborted: String {
            isChinese ? "已取消。" : "Aborted."
        }
        public static func deleted(_ name: String) -> String {
            isChinese ? "已刪除環境：\(name)" : "Deleted environment: \(name)"
        }
        public static var reservedName: String {
            isChinese
                ? "'default' 是保留的環境，無法刪除。"
                : "'default' is a reserved environment and cannot be deleted."
        }
    }

    // MARK: - CurrentCommand

    public enum Current {
        public static var abstract: String {
            isChinese ? "顯示目前啟用的環境名稱" : "Print the name of the active environment"
        }
        public static var noActive: String {
            isChinese ? "（無啟用的環境）" : "(no active environment)"
        }
    }

    // MARK: - InfoCommand

    public enum Info {
        public static var abstract: String {
            isChinese ? "顯示 orbital 環境的詳細資訊" : "Show details of an orbital environment"
        }
        public static var nameHelp: String {
            isChinese ? "環境名稱（預設為目前啟用的環境）" : "Environment name (defaults to active environment)"
        }
        public static var noActive: String {
            isChinese
                ? "沒有啟用的環境。請指定名稱或先執行 'orbital use <name>'。"
                : "No active environment. Specify a name or run 'orbital use <name>' first."
        }
        public static var labelName: String { isChinese ? "名稱：       " : "Name:        " }
        public static var labelID: String { isChinese ? "ID：         " : "ID:          " }
        public static var labelPath: String { isChinese ? "路徑：       " : "Path:        " }
        public static var labelDescription: String { isChinese ? "描述：       " : "Description: " }
        public static var labelCreated: String { isChinese ? "建立時間：   " : "Created:     " }
        public static var labelLastUsed: String { isChinese ? "上次使用：   " : "Last Used:   " }
        public static var labelTools: String { isChinese ? "工具：       " : "Tools:       " }
        public static var labelEnvVars: String { isChinese ? "環境變數：   " : "Env Vars:    " }
        public static var none: String { isChinese ? "（無）" : "(none)" }
    }

    // MARK: - ListCommand

    public enum List {
        public static var abstract: String {
            isChinese ? "列出所有 orbital 環境" : "List all orbital environments"
        }
        public static var empty: String {
            isChinese
                ? "找不到任何環境。使用以下指令建立：orbital create <name>"
                : "No environments found. Create one with: orbital create <name>"
        }
        public static var header: String {
            isChinese
                ? "  名稱        工具                    上次使用"
                : "  NAME        TOOLS                   LAST USED"
        }
    }

    // MARK: - RenameCommand

    public enum Rename {
        public static var abstract: String {
            isChinese ? "重新命名 orbital 環境" : "Rename an orbital environment"
        }
        public static var nameHelp: String {
            isChinese ? "目前的環境名稱" : "Current environment name"
        }
        public static var newNameHelp: String {
            isChinese ? "新的環境名稱" : "New environment name"
        }
        public static var reservedName: String {
            isChinese
                ? "'default' 是保留的環境名稱，無法重新命名。"
                : "'default' is a reserved environment and cannot be renamed."
        }
        public static func renamed(_ old: String, _ new: String) -> String {
            isChinese
                ? "已將環境 '\(old)' 重新命名為 '\(new)'"
                : "Renamed environment '\(old)' to '\(new)'"
        }
    }

    // MARK: - SetEnvCommand / UnsetEnvCommand

    public enum EnvVar {
        public static var setAbstract: String {
            isChinese ? "設定環境中的設定值" : "Set configuration values in an environment"
        }
        public static var unsetAbstract: String {
            isChinese ? "移除環境中的設定值" : "Remove configuration values from an environment"
        }
        public static var envHelp: String {
            isChinese
                ? "環境名稱（預設為 ORBITAL_ACTIVE_ENV）"
                : "Environment name (defaults to ORBITAL_ACTIVE_ENV)"
        }
        public static var noActive: String {
            isChinese
                ? "沒有啟用的環境。請先執行 'orbital use <name>'，或使用 -e <name>。"
                : "No active environment. Run 'orbital use <name>' first, or use -e <name>."
        }
        public static func set(_ key: String, _ envName: String) -> String {
            isChinese
                ? "已在環境 '\(envName)' 中設定 \(key)"
                : "Set \(key) in environment '\(envName)'"
        }
        public static func unset(_ key: String, _ envName: String) -> String {
            isChinese
                ? "已從環境 '\(envName)' 中移除 \(key)"
                : "Unset \(key) from environment '\(envName)'"
        }
    }

    // MARK: - ToolsCommand

    public enum Tools {
        public static var abstract: String {
            isChinese
                ? "管理環境的工具（互動式多選）"
                : "Manage tools for an environment (interactive multi-select)"
        }
        public static var envHelp: String {
            isChinese
                ? "環境名稱（預設為目前啟用的環境）"
                : "Environment name (defaults to active environment)"
        }
        public static var noActive: String {
            isChinese
                ? "沒有啟用的環境。請先執行 'orbital use <name>'，或使用 -e <name>。"
                : "No active environment. Run 'orbital use <name>' first, or use -e <name>."
        }
        public static func wizardTitle(_ envName: String) -> String {
            isChinese
                ? "選擇 '\(envName)' 的工具（↑↓ 移動，空白鍵切換，Enter 確認）："
                : "Select tools for '\(envName)' (↑↓ move, space toggle, enter confirm):"
        }
        public static func removed(_ tool: String) -> String {
            isChinese ? "已移除 \(tool)" : "Removed \(tool)"
        }
        public static func added(_ tool: String) -> String {
            isChinese ? "已加入 \(tool)" : "Added \(tool)"
        }
        public static var noChanges: String {
            isChinese ? "沒有變更。" : "No changes."
        }
    }

    // MARK: - UseCommand

    public enum Use {
        public static var abstract: String {
            isChinese ? "在目前的 shell 中啟用環境" : "Activate an environment in the current shell"
        }
        public static var nameHelp: String {
            isChinese ? "環境名稱" : "Environment name"
        }
        public static var needsShellIntegration: String {
            isChinese
                ? "error: 'orbital use' 需要 shell 整合。\n請執行 'orbital setup' 安裝後，重新啟動終端機。\n"
                : "error: 'orbital use' requires shell integration.\nRun 'orbital setup' to install it, then restart your terminal.\n"
        }
    }

    // MARK: - WhichCommand

    public enum Which {
        public static var abstract: String {
            isChinese
                ? "顯示目前環境中工具的設定目錄路徑"
                : "Print the config directory path for a tool in the active environment"
        }
        public static var toolHelp: String {
            isChinese ? "工具名稱：claude、codex 或 gemini" : "Tool name: claude, codex, or gemini"
        }
        public static func unknownTool(_ tool: String) -> String {
            isChinese
                ? "未知工具 '\(tool)'。可用工具：claude, codex, gemini"
                : "Unknown tool '\(tool)'. Valid tools: claude, codex, gemini"
        }
        public static var noActive: String {
            isChinese
                ? "沒有啟用的環境。請先執行 'orbital use <name>'。"
                : "No active environment. Run 'orbital use <name>' first."
        }
    }

    // MARK: - SetupCommand

    public enum Setup {
        public static var abstract: String {
            isChinese
                ? "安裝 orbital shell 整合（使用：eval \"$(orbital setup)\"）"
                : "Install orbital shell integration (use: eval \"$(orbital setup)\")"
        }
        public static var shellHelp: String {
            isChinese
                ? "Shell 類型 (bash, zsh)。未指定時自動偵測。"
                : "Shell type to configure (bash, zsh). Auto-detected if omitted."
        }
        public static func unsupportedShell(_ shell: String) -> String {
            isChinese
                ? "不支援的 shell '\(shell)'。支援：bash, zsh"
                : "Unsupported shell '\(shell)'. Supported: bash, zsh"
        }
        public static func alreadyPresent(_ path: String) -> String {
            isChinese
                ? "orbital: shell 整合已存在於 \(path)\n"
                : "orbital: shell integration already present in \(path)\n"
        }
        public static func addedTo(_ path: String) -> String {
            isChinese
                ? "orbital: 已加入到 \(path)\n"
                : "orbital: added to \(path)\n"
        }
        public static func failedToWrite(_ path: String, _ error: String) -> String {
            isChinese
                ? "orbital: 寫入 \(path) 失敗：\(error)\n"
                : "orbital: failed to write \(path): \(error)\n"
        }
        public static func wroteActivate(_ path: String) -> String {
            isChinese
                ? "orbital: 已產生 \(path)\n"
                : "orbital: wrote \(path)\n"
        }
        public static func migratedRc(_ path: String) -> String {
            isChinese
                ? "orbital: 已將 \(path) 中的 eval 改為 source\n"
                : "orbital: migrated \(path) from eval to source\n"
        }
    }

    // MARK: - InitCommand

    public enum Init {
        public static var abstract: String {
            isChinese
                ? "輸出 shell 整合腳本（加入 shell rc：eval \"$(orbital init)\"）"
                : "Output shell integration script (add to shell rc: eval \"$(orbital init)\")"
        }
    }

    // MARK: - Tool flag help (shared)

    public enum ToolFlag {
        public static var claude: String {
            isChinese ? "Anthropic Claude（預設）" : "Anthropic Claude (default)"
        }
        public static var codex: String {
            isChinese ? "OpenAI Codex" : "OpenAI Codex"
        }
        public static var gemini: String {
            isChinese ? "Google Gemini" : "Google Gemini"
        }
    }

    // MARK: - ResumeCommand

    public enum Resume {
        public static var abstract: String {
            isChinese
                ? "用 index 接續 AI tool session"
                : "Resume an AI tool session by index"
        }
        public static var noIndex: String {
            isChinese
                ? "請指定 session index。用 orbital sessions 查看列表。"
                : "Please specify a session index. Run orbital sessions to see the list."
        }
        public static func indexOutOfRange(_ index: Int, _ count: Int) -> String {
            isChinese
                ? "Index \(index) 超出範圍（共 \(count) 個 session）。"
                : "Index \(index) out of range (\(count) sessions available)."
        }
    }

    // MARK: - DelegateCommand

    public enum Delegate {
        public static var abstract: String {
            isChinese
                ? "委派任務給指定環境的 AI 工具"
                : "Delegate a task to an AI tool in a specific environment"
        }
        public static var envHelp: String {
            isChinese
                ? "環境名稱（預設為目前啟用的環境）"
                : "Environment name (defaults to active environment)"
        }
        public static var promptHelp: String {
            isChinese
                ? "要委派的任務描述"
                : "Task prompt to delegate"
        }
    }

    // MARK: - RunCommand

    public enum Run {
        public static var abstract: String {
            isChinese
                ? "在指定環境中執行指令"
                : "Run a command in a specific environment"
        }
        public static var envHelp: String {
            isChinese
                ? "環境名稱（預設為目前啟用的環境）"
                : "Environment name (defaults to active environment)"
        }
        public static var commandHelp: String {
            isChinese
                ? "要執行的指令及參數"
                : "Command and arguments to run"
        }
        public static var noCommand: String {
            isChinese
                ? "請指定要執行的指令。例如：orbital run -e work claude --resume <id>"
                : "No command specified. Example: orbital run -e work claude --resume <id>"
        }
    }

    // MARK: - SessionsCommand

    public enum Sessions {
        public static var abstract: String {
            isChinese
                ? "列出當前專案的 AI tool session"
                : "List AI tool sessions for the current project"
        }
        public static var noSessions: String {
            isChinese
                ? "在此專案中找不到任何 session。"
                : "No sessions found for this project."
        }
    }

    // MARK: - MemoryCommand

    public enum Memory {
        public static var abstract: String {
            isChinese
                ? "管理共享專案記憶"
                : "Manage shared project memory"
        }
        public static var exportAbstract: String {
            isChinese
                ? "匯出當前專案的共享記憶"
                : "Export shared memory for the current project"
        }
        public static var outputHelp: String {
            isChinese
                ? "輸出檔案路徑（預設：ORBITAL_MEMORY.md）"
                : "Output file path (default: ORBITAL_MEMORY.md)"
        }
        public static var noMemory: String {
            isChinese
                ? "此專案沒有共享記憶。"
                : "No shared memory for this project."
        }
        public static func exported(_ path: String) -> String {
            isChinese
                ? "已匯出至 \(path)"
                : "Exported to \(path)"
        }
    }

    // MARK: - MCPSetupCommand

    public enum MCPSetup {
        public static var abstract: String {
            isChinese
                ? "MCP 整合管理"
                : "MCP integration management"
        }
        public static var setupAbstract: String {
            isChinese
                ? "在當前專案設定 Orbital MCP server"
                : "Set up Orbital MCP server for the current project"
        }
        public static var success: String {
            isChinese
                ? "Orbital MCP server 與 slash commands 已設定完成。重新啟動 AI tool 即可使用 /orbital:delegate 和 /orbital:sessions。"
                : "Orbital MCP server and slash commands installed. Restart your AI tool to use /orbital:delegate and /orbital:sessions."
        }
        public static func wroteSettings(_ path: String) -> String {
            isChinese
                ? "orbital: 已寫入 \(path)\n"
                : "orbital: wrote \(path)\n"
        }
    }

    // MARK: - MCPServerCommand

    public enum MCPServerCmd {
        public static var abstract: String {
            isChinese
                ? "啟動 MCP server（供 Claude Code 等工具整合）"
                : "Start MCP server (for Claude Code integration)"
        }
    }

    // MARK: - ExportCommand / UnexportCommand

    public enum Export {
        public static var abstract: String {
            "Internal: print export lines for a named environment (called by shell function)"
        }
    }

    public enum Unexport {
        public static var abstract: String {
            "Internal: print unset lines for a named environment (called by shell function)"
        }
    }

    // MARK: - ToolSetup

    public enum ToolSetup {
        public static func notInstalled(_ tool: String) -> String {
            isChinese ? "\(tool) 尚未安裝。" : "\(tool) is not installed."
        }
        public static var installNow: String {
            isChinese ? "現在安裝嗎？[Y/n] " : "Install it now? [Y/n] "
        }
        public static func skipping(_ tool: String) -> String {
            isChinese ? "跳過 \(tool) 設定。\n" : "Skipping \(tool) setup.\n"
        }
        public static func installing(_ tool: String, _ cmd: String) -> String {
            isChinese
                ? "正在安裝 \(tool)（\(cmd)）...\n"
                : "Installing \(tool) (\(cmd))...\n"
        }
        public static func installed(_ tool: String) -> String {
            isChinese ? "\u{2713} \(tool) 已安裝" : "\u{2713} \(tool) installed"
        }
    }
}
