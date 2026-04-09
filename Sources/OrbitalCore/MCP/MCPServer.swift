import Foundation

/// Minimal MCP (Model Context Protocol) server over stdin/stdout JSON-RPC 2.0.
public struct MCPServer {

    private static let out = FileHandle.standardOutput
    private static let err = FileHandle.standardError

    public static func run() {
        log("Orbital MCP server starting")

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
                        "name": "orbital",
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

        log("Orbital MCP server exiting")
    }

    // MARK: - Tool definitions

    private static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "orbital_list",
                "description": "List all Orbital environments",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "orbital_sessions",
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
                "name": "orbital_delegate",
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
                "name": "orbital_current",
                "description": "Get the currently active Orbital environment name",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
        ]
    }

    // MARK: - Tool execution

    private static func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        switch name {
        case "orbital_list":
            return execCommand(["orbital", "list"])

        case "orbital_sessions":
            var args = ["orbital", "sessions"]
            if let tool = arguments["tool"] as? String {
                args.append("--\(tool)")
            }
            return execCommand(args)

        case "orbital_delegate":
            guard let prompt = arguments["prompt"] as? String else {
                return toolError("Missing required parameter: prompt")
            }
            var args = ["orbital", "delegate"]
            if let env = arguments["environment"] as? String {
                args += ["-e", env]
            }
            if let tool = arguments["tool"] as? String {
                args.append("--\(tool)")
            }
            args.append(prompt)
            return execCommand(args)

        case "orbital_current":
            return execCommand(["orbital", "current"])

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
        // Read from OrbitalCommand would create a circular dep, just hardcode sync point
        "0.2.8"
    }
}
