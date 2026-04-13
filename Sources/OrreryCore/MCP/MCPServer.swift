import Foundation

/// Minimal MCP (Model Context Protocol) server over stdin/stdout JSON-RPC 2.0.
public struct MCPServer {

    private static let out = FileHandle.standardOutput
    private static let err = FileHandle.standardError

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
        [
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
                "description": "Read the shared Orrery memory for the current project. This memory is shared across all AI tools (Claude, Codex, Gemini) and all Orrery environments. Use this to recall project decisions, architecture notes, conventions, or anything previously saved. Always read before writing to avoid overwriting existing knowledge. If pending sync fragments are present, consolidate them into the memory and write back with append=false to complete integration.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orrery_memory_write",
                "description": "Write or append to the shared Orrery memory for the current project. Use markdown format. This memory persists across sessions and is shared across all AI tools (Claude, Codex, Gemini) and environments. Use this to save: project decisions (e.g. 'we chose PostgreSQL 16'), architecture notes, coding conventions, deployment info, or anything the team should remember. Default is append mode — set append=false only to rewrite the entire memory.",
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
    }

    // MARK: - Tool execution

    private static func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        switch name {
        case "orrery_list":
            return execCommand(["orrery", "list"])

        case "orrery_sessions":
            var args = ["orrery", "sessions"]
            if let tool = arguments["tool"] as? String {
                args.append("--\(tool)")
            }
            return execCommand(args)

        case "orrery_delegate":
            guard let prompt = arguments["prompt"] as? String else {
                return toolError("Missing required parameter: prompt")
            }
            var args = ["orrery", "delegate"]
            if let env = arguments["environment"] as? String {
                args += ["-e", env]
            }
            if let tool = arguments["tool"] as? String {
                args.append("--\(tool)")
            }
            args.append(prompt)
            return execCommand(args)

        case "orrery_current":
            return execCommand(["orrery", "current"])

        case "orrery_memory_read":
            return readMemory()

        case "orrery_memory_write":
            guard let content = arguments["content"] as? String else {
                return toolError("Missing required parameter: content")
            }
            let append = arguments["append"] as? Bool ?? true
            return writeMemory(content: content, append: append)

        default:
            return toolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Process execution

    private static func execCommand(_ args: [String]) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return toolError("Failed to run: \(args.joined(separator: " ")): \(error)")
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let msg = errOutput.isEmpty ? output : errOutput
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
        let store = EnvironmentStore.default
        return store.memoryFile(projectKey: projectKey, envName: envName)
            .deletingLastPathComponent()
    }

    private static func sharedMemoryFile() -> URL {
        let projectKey = FileManager.default.currentDirectoryPath
            .replacingOccurrences(of: "/", with: "-")
        let envName = ProcessInfo.processInfo.environment["ORRERY_ACTIVE_ENV"]
        return EnvironmentStore.default.memoryFile(projectKey: projectKey, envName: envName)
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

    /// Ensure ORRERY_MEMORY.md is symlinked into Claude's auto-memory directory
    /// so Claude picks it up automatically at session start without any CLAUDE.md setup.
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

    private static func toolError(_ message: String) -> [String: Any] {
        [
            "content": [
                ["type": "text", "text": message]
            ],
            "isError": true
        ]
    }

    private static func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var str = String(data: data, encoding: .utf8) else { return }
        str += "\n"
        out.write(Data(str.utf8))
    }

    private static func log(_ message: String) {
        err.write(Data("[\(message)]\n".utf8))
    }

    private static func currentVersion() -> String {
        // Read from OrreryCommand would create a circular dep, just hardcode sync point
        "2.2.0"
    }
}
