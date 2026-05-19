import Foundation

/// Minimal MCP (Model Context Protocol) server over stdin/stdout JSON-RPC 2.0.
@MainActor
public struct MCPServer {

    private typealias ToolHandler = @MainActor ([String: Any]) async -> [String: Any]

    private static let out = FileHandle.standardOutput
    private static let err = FileHandle.standardError
    @MainActor private static var extraToolSchemas: [[String: Any]] = []
    @MainActor private static var extraToolHandlers: [String: ToolHandler] = [:]

    @MainActor
    public static func registerTool(
        schema: [String: Any],
        handler: @escaping @MainActor ([String: Any]) async -> [String: Any]
    ) {
        guard let name = schema["name"] as? String, !name.isEmpty else { return }

        if let index = extraToolSchemas.firstIndex(where: { ($0["name"] as? String) == name }) {
            extraToolSchemas[index] = schema
        } else {
            extraToolSchemas.append(schema)
        }
        extraToolHandlers[name] = handler
    }

    @MainActor
    public static func run() async {
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
                let result = await callTool(name: toolName, arguments: args)
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
            [
                "name": "orrery_user_memory_read",
                "description": "Read the user-global Orrery memory. This memory follows you across all projects and all environments — use it for facts about who you are (the user), cross-project preferences, and tool/account references. Always read before writing to avoid overwriting existing knowledge. If pending sync fragments are present, consolidate them into MEMORY.md and write back with append=false.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
        ]

        return builtInTools + registeredToolSchemas()
    }

    // MARK: - Tool execution

    @MainActor
    private static func callTool(name: String, arguments: [String: Any]) async -> [String: Any] {
        switch name {
        case "orrery_list":
            return await execCommand(["orrery-bin", "list"])

        case "orrery_sessions":
            var args = ["orrery-bin", "sessions"]
            if let tool = arguments["tool"] as? String {
                args.append("--\(tool)")
            }
            return await execCommand(args)

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
            return await execCommand(args)

        case "orrery_current":
            return await execCommand(["orrery-bin", "current"])

        case "orrery_memory_read":
            return readMemory()

        case "orrery_memory_write":
            guard let content = arguments["content"] as? String else {
                return toolError("Missing required parameter: content")
            }
            let append = arguments["append"] as? Bool ?? true
            return writeMemory(content: content, append: append)

        case "orrery_user_memory_read":
            return readUserMemory()

        default:
            if let handler = registeredHandler(for: name) {
                return await handler(arguments)
            }
            return toolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Process execution

    @MainActor
    public static func execCommand(_ args: [String]) async -> [String: Any] {
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
        let stdoutTask = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        process.waitUntilExit()

        let outputData = await stdoutTask.value
        let errData = await errTask.value
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errOutput = String(data: errData, encoding: .utf8) ?? ""

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

    private static func projectMemoryStore() -> MemoryStore {
        MemoryStore(directory: sharedMemoryDirectory())
    }

    private static func userMemoryStore() -> MemoryStore {
        MemoryStore(directory: EnvironmentStore.default.userMemoryDir())
    }

    private static func readUserMemory() -> [String: Any] {
        let store = userMemoryStore()
        let result = (try? store.read()) ?? .init(memory: "", fragments: [])

        var content = result.memory
        if !result.fragments.isEmpty {
            content += "\n\n---\n## Pending Memory Fragments (from sync)\n"
            content += "The following fragments were synced from other machines and need to be integrated.\n"
            content += "Please consolidate them into the memory above, then write back with append=false.\n"
            content += "After integration, the fragment files will be cleaned up automatically.\n\n"
            for f in result.fragments {
                content += "### \(f.filename)\n"
                content += f.content + "\n\n"
            }
        }

        if content.isEmpty {
            return [
                "content": [["type": "text", "text": "(no user-global memory yet)"]],
                "isError": false
            ]
        }
        return [
            "content": [["type": "text", "text": content]],
            "isError": false
        ]
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
        let store = projectMemoryStore()
        let result = (try? store.read()) ?? .init(memory: "", fragments: [])

        var content = result.memory
        if !result.fragments.isEmpty {
            content += "\n\n---\n## Pending Memory Fragments (from sync)\n"
            content += "The following fragments were synced from other machines and need to be integrated.\n"
            content += "Please consolidate them into the memory above, then write back with append=false.\n"
            content += "After integration, the fragment files will be cleaned up automatically.\n\n"
            for f in result.fragments {
                content += "### \(f.filename)\n"
                content += f.content + "\n\n"
            }
        }

        if content.isEmpty {
            return [
                "content": [["type": "text", "text": "(no shared memory yet)"]],
                "isError": false
            ]
        }
        return [
            "content": [["type": "text", "text": content]],
            "isError": false
        ]
    }

    private static func writeMemory(content: String, append: Bool) -> [String: Any] {
        ensureClaudeSymlink()
        let store = projectMemoryStore()
        do {
            try store.write(content: content, append: append)
            let path = store.directory.appendingPathComponent("MEMORY.md").path
            return [
                "content": [["type": "text", "text": "Memory updated: \(path)"]],
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

    @MainActor private static func registeredToolSchemas() -> [[String: Any]] {
        return extraToolSchemas
    }

    @MainActor private static func registeredHandler(for name: String) -> ToolHandler? {
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

