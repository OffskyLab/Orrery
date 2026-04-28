import Foundation
import OrreryCore

public enum MagiMCPTools {
    /// Register the `orrery_magi` MCP tool. Phase 2 Step 4 removed the
    /// in-process fallback: this throws if the sidecar binary cannot
    /// be resolved, instead of silently registering a hardcoded schema
    /// and routing to an `orrery magi` re-exec.
    public static func register(on server: MCPServer.Type) throws {
        let sidecar = try MagiSidecar.resolve()
        guard let schema = sidecar.mcpSchema else {
            throw MagiSidecarError.mcpSchemaFetchFailed
        }

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

                let timeout: TimeInterval = 600
                let result = MagiSidecar.spawnAndCapture(
                    binary: sidecar.path,
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
        )
    }
}
