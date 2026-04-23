import Foundation

/// Minimal MCP (Model Context Protocol) server over stdin/stdout JSON-RPC 2.0.
public struct MCPServer {

    private typealias ToolHandler = ([String: Any]) -> [String: Any]

    private static let out = FileHandle.standardOutput
    private static let err = FileHandle.standardError
    private static nonisolated(unsafe) var extraToolSchemas: [[String: Any]] = []
    private static nonisolated(unsafe) var extraToolHandlers: [String: ToolHandler] = [:]
    private static let extraToolsLock = NSLock()

    public static func registerTool(
        schema: [String: Any],
        handler: @escaping ([String: Any]) -> [String: Any]
    ) {
        guard let name = schema["name"] as? String, !name.isEmpty else { return }

        extraToolsLock.lock()
        defer { extraToolsLock.unlock() }

        if let index = extraToolSchemas.firstIndex(where: { ($0["name"] as? String) == name }) {
            extraToolSchemas[index] = schema
        } else {
            extraToolSchemas.append(schema)
        }
        extraToolHandlers[name] = handler
    }

    public static func run() {
        log("Orrery MCP server starting")

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let id = json["id"]  // may be Int or String or nil (notification)
            let method = json["method"] as? String ?? ""
            let params = json["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                respond(id: id, result: [
                    "protocolVersion": "2025-03-26",
                    "capabilities": [
                        "tools": ["listChanged": false]
                    ],
                    "serverInfo": [
                        "name": "orrery",
                        "version": currentVersion()
                    ]
                ])

            case "notifications/initialized":
                // No response needed for notifications
                break

            case "tools/list":
                respond(id: id, result: ["tools": toolDefinitions()])

            case "tools/call":
                let toolName = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                let result = callTool(name: toolName, arguments: args)
                respond(id: id, result: result)

            default:
                respondError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }

        log("Orrery MCP server exiting")
    }

    // MARK: - Tool definitions

    private static func toolDefinitions() -> [[String: Any]] {
        let builtInTools: [[String: Any]] = [
            [
                "name": "orrery_list",
                "description": "List all Orrery environments",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_sessions",
                "description": "List AI tool sessions for the current project",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tool": [
                            "type": "string",
                            "description": "Filter by tool: claude, codex, gemini",
                            "enum": ["claude", "codex", "gemini"]
                        ]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_delegate",
                "description": "Delegate a task to an AI tool in a specific environment. Uses non-interactive mode.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "prompt": [
                            "type": "string",
                            "description": "The task to delegate"
                        ],
                        "environment": [
                            "type": "string",
                            "description": "Environment name (e.g. work, personal)"
                        ],
                        "tool": [
                            "type": "string",
                            "description": "AI tool to use (default: claude)",
                            "enum": ["claude", "codex", "gemini"]
                        ]
                    ],
                    "required": ["prompt"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_current",
                "description": "Get the currently active Orrery environment name",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_memory_read",
                "description": "Read the shared Orrery memory (MEMORY.md) for the current project. This memory directory is shared across all AI tools (Claude, Codex, Gemini) and all Orrery environments. Use this to recall project decisions, architecture notes, conventions, or anything previously saved. Always read before writing to avoid overwriting existing knowledge. If pending sync fragments are present, consolidate them into MEMORY.md and write back with append=false to complete integration.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_spec",
                "description": "Generate a structured implementation spec from a discussion report or any Markdown input.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "input": [
                            "type": "string",
                            "description": "Path to the input Markdown file"
                        ],
                        "output": [
                            "type": "string",
                            "description": "Output path for the generated spec (optional)"
                        ],
                        "profile": [
                            "type": "string",
                            "description": "Spec profile name: default, minimal, rfc, or a custom template name"
                        ],
                        "review": [
                            "type": "boolean",
                            "description": "Enable dual-model review (default: false)"
                        ],
                        "environment": [
                            "type": "string",
                            "description": "Environment name (default: active environment)"
                        ]
                    ],
                    "required": ["input"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_spec_verify",
                "description": "Verify a spec's acceptance criteria. Default dry-run (no shell commands executed); pass execute=true to run sandboxed commands. Output is a structured JSON result with verification.test_results, diff_summary, and optional review. Exit code is authoritative from verify (review is advisory only).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "spec_path": [
                            "type": "string",
                            "description": "Path to spec markdown file (relative to CWD or absolute)"
                        ],
                        "tool": [
                            "type": "string",
                            "enum": ["claude", "codex", "gemini"],
                            "description": "Delegate tool for optional review"
                        ],
                        "resume_session_id": [
                            "type": "string",
                            "description": "Accepted but ignored in verify mode (verify always uses a fresh session); appears as a note in stderr"
                        ],
                        "timeout": [
                            "type": "integer",
                            "description": "Overall seconds across all acceptance commands (default 600)"
                        ],
                        "per_command_timeout": [
                            "type": "integer",
                            "description": "Per-command seconds before SIGTERM (default 60)"
                        ],
                        "execute": [
                            "type": "boolean",
                            "description": "Disable dry-run and actually execute sandboxed shell commands. Default false (dry-run)."
                        ],
                        "strict_policy": [
                            "type": "boolean",
                            "description": "Treat any policy_blocked command as failure (non-zero exit). Default false."
                        ],
                        "review": [
                            "type": "boolean",
                            "description": "Spawn an advisory review after verify completes (only when verify fully passes). Default false."
                        ],
                        "environment": [
                            "type": "string",
                            "description": "Environment name (default: active environment)"
                        ]
                    ],
                    "required": ["spec_path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_spec_implement",
                "description": "Run the implement phase of a spec. Spawns a delegate agent (claude-code/codex/gemini) in a detached subprocess that writes code per the spec's 介面合約 / 改動檔案 / 實作步驟 / 驗收標準 sections. Returns IMMEDIATELY with session_id + status='running'; use orrery_spec_status to poll until status becomes done/failed/aborted. The delegate is constrained (no git commit/push, no swift build/test — those belong to orrery_spec_verify).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "spec_path": [
                            "type": "string",
                            "description": "Path to spec markdown file (relative to CWD or absolute). Must contain all four mandatory headings: 介面合約, 改動檔案, 實作步驟, 驗收標準."
                        ],
                        "tool": [
                            "type": "string",
                            "enum": ["claude", "codex", "gemini"],
                            "description": "Delegate CLI. Omit to auto-pick the first available."
                        ],
                        "resume_session_id": [
                            "type": "string",
                            "description": "Orrery spec-run session UUID returned by a prior orrery_spec_implement call. Do NOT pass the delegate agent's native session id — orrery resolves delegate resume internally."
                        ],
                        "timeout": [
                            "type": "integer",
                            "description": "Overall seconds the delegate subprocess may run before the wrapper's watchdog sends SIGTERM. Default 3600 (1h). Pass 0 to disable."
                        ],
                        "environment": [
                            "type": "string",
                            "description": "Environment name (default: active environment)."
                        ]
                    ],
                    "required": ["spec_path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_spec_status",
                "description": "Poll the status of a running orrery_spec_implement session. Suggested polling cadence: first 2s, then exponential backoff min(30s, prev * 1.5); after ~5min settle at 30s. Returns status running/done/failed/aborted, diff_summary, touched_files, completed_steps, failed_step, and optionally the tail of the progress jsonl.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": [
                            "type": "string",
                            "description": "Orrery spec-run session UUID from orrery_spec_implement."
                        ],
                        "include_log": [
                            "type": "boolean",
                            "description": "If true, include the last N lines of the progress jsonl in log_tail. Default false."
                        ],
                        "since_timestamp": [
                            "type": "string",
                            "description": "Optional ISO8601 timestamp; only events with ts greater than this are included in log_tail (useful for incremental polling)."
                        ]
                    ],
                    "required": ["session_id"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_memory_write",
                "description": "Write or append to the shared Orrery memory (MEMORY.md) for the current project. Use markdown format. This memory persists across sessions and is shared across all AI tools (Claude, Codex, Gemini) and environments. Use this to save: project decisions (e.g. 'we chose PostgreSQL 16'), architecture notes, coding conventions, deployment info, or anything the team should remember. Default is append mode — set append=false only to rewrite the entire MEMORY.md.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "content": [
                            "type": "string",
                            "description": "Markdown content to write to shared memory"
                        ],
                        "append": [
                            "type": "boolean",
                            "description": "If true, append to existing memory. If false, overwrite. Default: true"
                        ]
                    ],
                    "required": ["content"],
                    "additionalProperties": false
                ]
            ],
        ]

        return builtInTools + registeredToolSchemas()
    }

    // MARK: - Tool execution

    private static func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        switch name {
        case "orrery_list":
            return execCommand(["orrery-bin", "list"])

        case "orrery_sessions":
            var args = ["orrery-bin", "sessions"]
            if let tool = arguments["tool"] as? String {
                args.append("--\(tool)")
            }
            return execCommand(args)

        case "orrery_delegate":
            guard let prompt = arguments["prompt"] as? String else {
                return toolError("Missing required parameter: prompt")
            }
            var args = ["orrery-bin", "delegate"]
            if let env = arguments["environment"] as? String {
                args += ["-e", env]
            }
            if let tool = arguments["tool"] as? String {
                args.append("--\(tool)")
            }
            args.append(prompt)
            return execCommand(args)

        case "orrery_current":
            return execCommand(["orrery-bin", "current"])

        case "orrery_spec":
            guard let input = arguments["input"] as? String else {
                return toolError("Missing required parameter: input")
            }
            var args = ["orrery", "spec"]
            if let output = arguments["output"] as? String {
                args += ["-o", output]
            }
            if let profile = arguments["profile"] as? String {
                args += ["--profile", profile]
            }
            if let review = arguments["review"] as? Bool, review {
                args.append("--review")
            }
            if let env = arguments["environment"] as? String {
                args += ["-e", env]
            }
            args.append(input)
            return execCommand(args)

        case "orrery_spec_verify":
            guard let specPath = arguments["spec_path"] as? String else {
                return toolError("Missing required parameter: spec_path")
            }
            var args = ["orrery", "spec-run", "--mode", "verify", specPath]
            if let tool = arguments["tool"] as? String {
                args += ["--tool", tool]
            }
            if let rid = arguments["resume_session_id"] as? String {
                args += ["--resume-session-id", rid]
            }
            if let timeout = arguments["timeout"] as? Int {
                args += ["--timeout", String(timeout)]
            }
            if let pct = arguments["per_command_timeout"] as? Int {
                args += ["--per-command-timeout", String(pct)]
            }
            if let execute = arguments["execute"] as? Bool, execute {
                args.append("--execute")
            }
            if let strict = arguments["strict_policy"] as? Bool, strict {
                args.append("--strict-policy")
            }
            if let review = arguments["review"] as? Bool, review {
                args.append("--review")
            }
            if let env = arguments["environment"] as? String {
                args += ["-e", env]
            }
            return execCommand(args)

        case "orrery_spec_implement":
            guard let specPath = arguments["spec_path"] as? String else {
                return toolError("Missing required parameter: spec_path")
            }
            var args = ["orrery", "spec-run", "--mode", "implement", specPath]
            if let tool = arguments["tool"] as? String {
                args += ["--tool", tool]
            }
            if let rid = arguments["resume_session_id"] as? String {
                args += ["--resume-session-id", rid]
            }
            if let timeout = arguments["timeout"] as? Int {
                args += ["--timeout", String(timeout)]
            }
            if let env = arguments["environment"] as? String {
                args += ["-e", env]
            }
            // MCP path is always detached (early-return); --watch is CLI-only
            // so clients don't hit the 60-120s MCP transport timeout.
            return execCommand(args)

        case "orrery_spec_status":
            guard let sid = arguments["session_id"] as? String else {
                return toolError("Missing required parameter: session_id")
            }
            var args = ["orrery", "spec-run", "--mode", "status",
                        "--session-id", sid, "/dev/null"]
            if let includeLog = arguments["include_log"] as? Bool, includeLog {
                args.append("--include-log")
            }
            if let since = arguments["since_timestamp"] as? String {
                args += ["--since-timestamp", since]
            }
            return execCommand(args)

        case "orrery_memory_read":
            return readMemory()

        case "orrery_memory_write":
            guard let content = arguments["content"] as? String else {
                return toolError("Missing required parameter: content")
            }
            let append = arguments["append"] as? Bool ?? true
            return writeMemory(content: content, append: append)

        default:
            if let handler = registeredHandler(for: name) {
                return handler(arguments)
            }
            return toolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Process execution

    public static func execCommand(_ args: [String]) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return toolError("Failed to run: \(args.joined(separator: " ")): \(error)")
        }

        // Drain BOTH pipes concurrently before waitUntilExit. If the child
        // writes more than the pipe buffer (~16 KB on macOS) and we wait
        // first, the child blocks on a full pipe and we block waiting for
        // the child → deadlock. Reading sequentially isn't enough either,
        // since whichever pipe we read second can fill while we're stuck
        // on the first.
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let outHandle = pipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        group.enter()
        DispatchQueue.global().async {
            outBox.set(outHandle.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.set(errHandle.readDataToEndOfFile())
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let output = String(data: outBox.snapshot, encoding: .utf8) ?? ""
        let errOutput = String(data: errBox.snapshot, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            // Prefer stdout when it carries a structured payload (e.g.
            // orrery_spec_verify emits a stable JSON object even on failure).
            // Fall back to stderr only when stdout is empty.
            let msg = output.isEmpty ? errOutput : output
            return toolError(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Strip ANSI escape codes for clean MCP output
        let clean = output.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )

        return [
            "content": [
                ["type": "text", "text": clean.trimmingCharacters(in: .whitespacesAndNewlines)]
            ],
            "isError": false
        ]
    }

    // MARK: - Shared memory

    private static func sharedMemoryDirectory() -> URL {
        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        return EnvironmentStore.default.memoryDir(projectKey: projectKey, envName: envName)
    }

    private static func sharedMemoryFile() -> URL {
        sharedMemoryDirectory().appendingPathComponent("MEMORY.md")
    }

    private static func fragmentsDirectory() -> URL {
        sharedMemoryDirectory().appendingPathComponent("fragments")
    }

    private static func peerName() -> String {
        ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
    }

    private static func writeFragment(content: String, action: String) {
        let dir = fragmentsDirectory()
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let peer = peerName()
        let id = UUID().uuidString.prefix(8).lowercased()
        let filename = "f-\(id)-\(peer).md"

        let body = """
        ---
        id: f-\(id)
        peer: \(peer)
        timestamp: \(timestamp)
        action: \(action)
        ---

        \(content)
        """

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: dir.appendingPathComponent(filename),
                           atomically: true, encoding: .utf8)
        } catch {
            log("Failed to write fragment: \(error.localizedDescription)")
        }
    }

    /// Remove all fragment files after consolidation.
    private static func cleanupFragments() {
        let dir = fragmentsDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasSuffix(".md") {
            try? fm.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    /// Ensure the Orrery memory directory is symlinked into Claude's auto-memory location
    /// so Claude picks up MEMORY.md + fragments automatically at session start, without any
    /// CLAUDE.md setup, and so writes land in the shared/syncable path.
    private static func ensureClaudeSymlink() {
        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        let claudeConfigDirPath = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.claude")
        let claudeConfigDir = URL(fileURLWithPath: claudeConfigDirPath)
        EnvironmentStore.default.linkOrreryMemory(
            projectKey: projectKey,
            envName: envName ?? ReservedEnvironment.defaultName,
            claudeConfigDir: claudeConfigDir
        )
    }

    private static func readMemory() -> [String: Any] {
        ensureClaudeSymlink()
        let file = sharedMemoryFile()
        var content = ""
        if FileManager.default.fileExists(atPath: file.path),
           let existing = try? String(contentsOf: file, encoding: .utf8) {
            content = existing
        }

        // Check for pending fragments from other peers
        let fragments = pendingFragments()
        if !fragments.isEmpty {
            content += "\n\n---\n## Pending Memory Fragments (from sync)\n"
            content += "The following fragments were synced from other machines and need to be integrated.\n"
            content += "Please consolidate them into the memory above, then write back with append=false.\n"
            content += "After integration, the fragment files will be cleaned up automatically.\n\n"
            for fragment in fragments {
                content += "### \(fragment.filename)\n"
                content += fragment.content + "\n\n"
            }
        }

        if content.isEmpty {
            return [
                "content": [
                    ["type": "text", "text": "(no shared memory yet)"]
                ],
                "isError": false
            ]
        }

        return [
            "content": [
                ["type": "text", "text": content]
            ],
            "isError": false
        ]
    }

    private struct Fragment {
        let filename: String
        let content: String
    }

    private static func pendingFragments() -> [Fragment] {
        let dir = fragmentsDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }

        return files
            .filter { $0.hasSuffix(".md") }
            .sorted()
            .compactMap { filename -> Fragment? in
                let path = dir.appendingPathComponent(filename)
                guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
                return Fragment(filename: filename, content: content)
            }
    }

    private static func writeMemory(content: String, append: Bool) -> [String: Any] {
        ensureClaudeSymlink()
        let file = sharedMemoryFile()
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            if append && fm.fileExists(atPath: file.path) {
                let existing = try String(contentsOf: file, encoding: .utf8)
                try (existing + "\n" + content).write(to: file, atomically: true, encoding: .utf8)
            } else {
                try content.write(to: file, atomically: true, encoding: .utf8)
                // Overwrite means consolidation — clean up integrated fragments
                cleanupFragments()
            }

            writeFragment(content: content, action: append ? "append" : "overwrite")

            return [
                "content": [
                    ["type": "text", "text": "Memory updated: \(file.path)"]
                ],
                "isError": false
            ]
        } catch {
            return toolError("Failed to write memory: \(error.localizedDescription)")
        }
    }

    // MARK: - JSON-RPC helpers

    private static func respond(id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id { response["id"] = id }
        send(response)
    }

    private static func respondError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        send(response)
    }

    public static func toolError(_ message: String) -> [String: Any] {
        [
            "content": [
                ["type": "text", "text": message]
            ],
            "isError": true
        ]
    }

    private static func registeredToolSchemas() -> [[String: Any]] {
        extraToolsLock.lock()
        defer { extraToolsLock.unlock() }
        return extraToolSchemas
    }

    private static func registeredHandler(for name: String) -> ToolHandler? {
        extraToolsLock.lock()
        defer { extraToolsLock.unlock() }
        return extraToolHandlers[name]
    }

    private static func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var str = String(data: data, encoding: .utf8) else { return }
        str += "\n"
        stdoutWrite(str)
    }

    private static func log(_ message: String) {
        stderrWrite("[\(message)]\n")
    }

    private static func currentVersion() -> String {
        OrreryVersion.current
    }
}

/// Mutable Data sink usable from concurrent `DispatchQueue.global().async`
/// reads under Swift 6 strict concurrency.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
