import Foundation
import OrreryCore

public enum MagiMCPTools {
    private enum ArgBuildResult {
        case success([String])
        case failure(String)
    }

    private enum ForwardedTool: String {
        case magi = "orrery_magi"
        case spec = "orrery_spec"
        case specVerify = "orrery_spec_verify"
        case specImplement = "orrery_spec_implement"
    }

    public static func register(on server: MCPServer.Type) throws {
        let sidecar = try MagiSidecar.resolve()

        for schema in sidecar.mcpSchemas {
            guard let name = schema["name"] as? String, name != "orrery_spec_status" else {
                continue
            }
            server.registerTool(schema: schema, handler: makeForwarder(server: server, name: name, sidecar: sidecar))
        }

        if sidecar.specRuntimeStable {
            server.registerTool(
                schema: specStatusSchema(),
                handler: makeStatusInlineHandler(server: server)
            )
        }
    }

    private static func specStatusSchema() -> [String: Any] {
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
        ]
    }

    private static func makeForwarder(
        server: MCPServer.Type,
        name: String,
        sidecar: MagiSidecar.ResolvedBinary
    ) -> ([String: Any]) -> [String: Any] {
        return { arguments in
            guard let tool = ForwardedTool(rawValue: name) else {
                return server.toolError("Unknown tool: \(name)")
            }

            let argv: [String]
            let timeout: TimeInterval
            let expectsJSON: Bool

            switch tool {
            case .magi:
                switch makeMagiArgs(arguments: arguments) {
                case .success(let built):
                    argv = built
                case .failure(let message):
                    return server.toolError(message)
                }
                timeout = 600
                expectsJSON = false
            case .spec:
                switch makeSpecArgs(arguments: arguments) {
                case .success(let built):
                    argv = built
                case .failure(let message):
                    return server.toolError(message)
                }
                timeout = 600
                expectsJSON = false
            case .specVerify:
                switch makeSpecVerifyArgs(arguments: arguments) {
                case .success(let built):
                    argv = built
                case .failure(let message):
                    return server.toolError(message)
                }
                timeout = 120
                expectsJSON = true
            case .specImplement:
                switch makeSpecImplementArgs(arguments: arguments) {
                case .success(let built):
                    argv = built
                case .failure(let message):
                    return server.toolError(message)
                }
                timeout = 600
                expectsJSON = true
            }

            let result = MagiSidecar.spawnAndCapture(
                binary: sidecar.path,
                args: argv,
                timeout: timeout
            )

            if result.timedOut {
                return server.toolError("orrery-magi timed out after \(Int(timeout))s")
            }

            let clean = stripANSI(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanStderr = stripANSI(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = clean.isEmpty ? cleanStderr : clean

            if expectsJSON, !message.isEmpty,
               message.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
                return server.toolError("orrery-magi returned invalid JSON for \(name)")
            }

            if result.exitCode != 0 {
                return server.toolError(message)
            }

            return textResponse(message)
        }
    }

    private static func makeStatusInlineHandler(
        server: MCPServer.Type
    ) -> ([String: Any]) -> [String: Any] {
        return { arguments in
            guard let sessionId = arguments["session_id"] as? String else {
                return server.toolError("Missing required parameter: session_id")
            }

            do {
                let state = try SpecRunStateReader.load(sessionId: sessionId)
                let includeLog = arguments["include_log"] as? Bool ?? false
                let since = arguments["since_timestamp"] as? String
                let logTail = includeLog
                    ? ((try? tailProgressLog(
                        path: SpecRunStateReader.progressLogPath(sessionId: sessionId).path,
                        lines: 50,
                        since: since
                    )) ?? [])
                    : []

                let status = SpecStatusResult.from(state: state, logTail: logTail)
                let json = try status.toJSONString()
                return textResponse(json, isError: state.status == "failed")
            } catch {
                return server.toolError("\(error)")
            }
        }
    }

    private static func makeMagiArgs(arguments: [String: Any]) -> ArgBuildResult {
        guard let topic = arguments["topic"] as? String else {
            return .failure("Missing required parameter: topic")
        }

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
        argv.append(topic)
        return .success(argv)
    }

    private static func makeSpecArgs(arguments: [String: Any]) -> ArgBuildResult {
        guard let input = arguments["input"] as? String else {
            return .failure("Missing required parameter: input")
        }

        var argv = ["spec"]
        if let output = arguments["output"] as? String {
            argv += ["-o", output]
        }
        if let profile = arguments["profile"] as? String {
            argv += ["--profile", profile]
        }
        if let review = arguments["review"] as? Bool, review {
            argv.append("--review")
        }
        if let environment = arguments["environment"] as? String {
            argv += ["-e", environment]
        }
        argv.append(input)
        return .success(argv)
    }

    private static func makeSpecVerifyArgs(arguments: [String: Any]) -> ArgBuildResult {
        guard let specPath = arguments["spec_path"] as? String else {
            return .failure("Missing required parameter: spec_path")
        }

        var argv = ["spec-run", "--mode", "verify", specPath]
        if let tool = arguments["tool"] as? String {
            argv += ["--tool", tool]
        }
        if let resumeSessionId = arguments["resume_session_id"] as? String {
            argv += ["--resume-session-id", resumeSessionId]
        }
        if let timeout = arguments["timeout"] as? Int {
            argv += ["--timeout", String(timeout)]
        }
        if let perCommandTimeout = arguments["per_command_timeout"] as? Int {
            argv += ["--per-command-timeout", String(perCommandTimeout)]
        }
        if let execute = arguments["execute"] as? Bool, execute {
            argv.append("--execute")
        }
        if let strictPolicy = arguments["strict_policy"] as? Bool, strictPolicy {
            argv.append("--strict-policy")
        }
        if let review = arguments["review"] as? Bool, review {
            argv.append("--review")
        }
        if let environment = arguments["environment"] as? String {
            argv += ["-e", environment]
        }
        return .success(argv)
    }

    private static func makeSpecImplementArgs(arguments: [String: Any]) -> ArgBuildResult {
        guard let specPath = arguments["spec_path"] as? String else {
            return .failure("Missing required parameter: spec_path")
        }

        var argv = ["spec-run", "--mode", "implement", specPath]
        if let tool = arguments["tool"] as? String {
            argv += ["--tool", tool]
        }
        if let resumeSessionId = arguments["resume_session_id"] as? String {
            argv += ["--resume-session-id", resumeSessionId]
        }
        if let timeout = arguments["timeout"] as? Int {
            argv += ["--timeout", String(timeout)]
        }
        if let environment = arguments["environment"] as? String {
            argv += ["-e", environment]
        }
        return .success(argv)
    }

    private static func textResponse(_ text: String, isError: Bool = false) -> [String: Any] {
        [
            "content": [
                ["type": "text", "text": text]
            ],
            "isError": isError
        ]
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }

    private struct ProgressEvent: Decodable {
        let ts: String
    }

    private static func tailProgressLog(path: String, lines: Int, since: String?) throws -> [String] {
        guard lines > 0, FileManager.default.fileExists(atPath: path) else { return [] }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let rawLines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        let filtered: [String]
        if let since {
            filtered = rawLines.filter { line in
                guard let data = line.data(using: .utf8),
                      let event = try? JSONDecoder().decode(ProgressEvent.self, from: data) else {
                    return false
                }
                return event.ts > since
            }
        } else {
            filtered = rawLines
        }

        return Array(filtered.suffix(lines))
    }
}
