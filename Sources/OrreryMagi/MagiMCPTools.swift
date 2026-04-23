import Foundation
import OrreryCore

public enum MagiMCPTools {
    public static func register(on server: MCPServer.Type) {
        server.registerTool(
            schema: [
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
            ],
            handler: { arguments in
                guard let topic = arguments["topic"] as? String else {
                    return server.toolError("Missing required parameter: topic")
                }

                var args = ["orrery", "magi"]
                let rounds = arguments["rounds"] as? Int ?? 1
                args += ["--rounds", String(rounds)]

                if let environment = arguments["environment"] as? String {
                    args += ["-e", environment]
                }
                if let tools = arguments["tools"] as? [String] {
                    for tool in tools {
                        args.append("--\(tool)")
                    }
                }
                if let roles = arguments["roles"] as? String {
                    args += ["--roles", roles]
                }
                if let spec = arguments["spec"] as? Bool, spec {
                    args.append("--spec")
                }

                args.append(topic)
                return server.execCommand(args)
            }
        )
    }
}
