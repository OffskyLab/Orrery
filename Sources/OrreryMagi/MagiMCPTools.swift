import Foundation
import OrreryCore

public enum MagiMCPTools {
    public static func register(on server: MCPServer.Type) throws {
        let sidecar = try MagiSidecar.resolveOrFallback()
        let schema = sidecar?.mcpSchema ?? hardcodedSchema

        server.registerTool(
            schema: schema,
            handler: { arguments in
                var argv: [String] = []
                let rounds = arguments["rounds"] as? Int ?? 1
                argv += ["--rounds", String(rounds)]
                if let environment = arguments["environment"] as? String {
                    argv += ["-e", environment]
                }
                if let tools = arguments["tools"] as? [String] {
                    for tool in tools {
                        argv.append("--\(tool)")
                    }
                }
                if let roles = arguments["roles"] as? String {
                    argv += ["--roles", roles]
                }
                if let spec = arguments["spec"] as? Bool, spec {
                    argv.append("--spec")
                }
                guard let topic = arguments["topic"] as? String else {
                    return server.toolError("Missing required parameter: topic")
                }
                argv.append(topic)

                if let binary = sidecar {
                    let timeout: TimeInterval = 600
                    let result = MagiSidecar.spawnAndCapture(
                        binary: binary.path,
                        args: argv,
                        timeout: timeout
                    )

                    if result.timedOut {
                        return server.toolError("orrery-magi timed out after \(Int(timeout))s")
                    }

                    if result.exitCode != 0 {
                        let message = result.stdout.isEmpty ? result.stderr : result.stdout
                        return server.toolError(message.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                    let clean = result.stdout.replacingOccurrences(
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

                return server.execCommand(["orrery", "magi"] + argv)
            }
        )
    }

    /// Hardcoded fallback used when the sidecar binary is not present
    /// or its --print-mcp-schema fails. Removed in Step 4.
    internal static var hardcodedSchema: [String: Any] {
        [
            "name": "orrery_magi",
            "description": "Start a multi-model discussion (Claude, Codex, Gemini) on a topic and produce a consensus report.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "topic": [
                        "type": "string",
                        "description": "Discussion topic. Use semicolons to separate sub-topics."
                    ],
                    "rounds": [
                        "type": "integer",
                        "description": "Maximum discussion rounds (default: 1 for MCP)"
                    ],
                    "tools": [
                        "type": "array",
                        "items": ["type": "string", "enum": ["claude", "codex", "gemini"]],
                        "description": "Participating tools (default: all installed)"
                    ],
                    "environment": [
                        "type": "string",
                        "description": "Environment name (default: active environment)"
                    ],
                    "roles": [
                        "type": "string",
                        "description": "Role preset (balanced, adversarial, security) or comma-separated role IDs"
                    ],
                    "spec": [
                        "type": "boolean",
                        "description": "Generate a spec from the discussion result (default: false)"
                    ]
                ],
                "required": ["topic"],
                "additionalProperties": false
            ]
        ]
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("[orrery-magi] \(message)\n".utf8))
    }
}
