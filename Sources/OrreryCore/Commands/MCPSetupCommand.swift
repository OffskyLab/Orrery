import ArgumentParser
import Foundation

public struct MCPSetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: L10n.MCPSetup.abstract,
        subcommands: [SetupSubcommand.self],
        defaultSubcommand: SetupSubcommand.self
    )

    public init() {}

    public struct SetupSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: L10n.MCPSetup.setupAbstract
        )

        public init() {}

        public func run() throws {
            let fm = FileManager.default
            let cwd = fm.currentDirectoryPath

            // 1. Register MCP server with each installed tool
            // MCP servers are launched by the host tool as non-interactive
            // subprocesses — there's no shell function wrapping them, so they
            // must invoke the renamed binary `orrery-bin` directly.
            Self.registerMCP(tool: "claude", args: ["claude", "mcp", "add", "--scope", "project", "orrery", "--", "orrery-bin", "mcp-server"])
            Self.registerMCP(tool: "codex", args: ["codex", "mcp", "add", "orrery", "--", "orrery-bin", "mcp-server"])
            Self.registerMCP(tool: "gemini", args: ["gemini", "mcp", "add", "orrery", "orrery-bin mcp-server"])

            // 2. Install slash commands
            try Self.installSlashCommands(projectDir: cwd)

            print(L10n.MCPSetup.success)
        }

        static func registerMCP(tool: String, args: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            // Strip IPC variables to prevent hanging inside AI tool sessions
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
            env.removeValue(forKey: "CLAUDE_CODE_EXECPATH")
            process.environment = env

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Tool not installed — skip silently
            }
        }

        static func installSlashCommands(projectDir: String) throws {
            let fm = FileManager.default
            let commandsDir = URL(fileURLWithPath: projectDir)
                .appendingPathComponent(".claude")
                .appendingPathComponent("commands")
            try fm.createDirectory(at: commandsDir, withIntermediateDirectories: true)

            // List available environments for the prompt
            let store = EnvironmentStore.default
            let envNames = (try? store.listNames().sorted()) ?? []
            let envList = ([ReservedEnvironment.defaultName] + envNames)
                .map { "- \($0)" }
                .joined(separator: "\n")

            let delegateMd = commandsDir.appendingPathComponent("orrery:delegate.md")
            let delegateContent = """
            # Delegate task to another account

            Delegate a task to an AI tool running under a different Orrery environment (account).

            Available environments:
            \(envList)

            Usage: Specify which environment to use and describe the task.

            Example: /orrery:delegate Use the "work" environment to review the recent changes for security issues.

            When this command is invoked, run:
            ```
            orrery delegate -e <environment> "$ARGUMENTS"
            ```

            Replace `<environment>` with the environment name the user specified.
            If no environment is specified, ask the user which one to use and show the available environments listed above.
            """
            try delegateContent.write(to: delegateMd, atomically: true, encoding: .utf8)

            let sessionsMd = commandsDir.appendingPathComponent("orrery:sessions.md")
            let sessionsContent = """
            # List AI sessions

            List all AI tool sessions for the current project.

            When this command is invoked, run:
            ```
            orrery sessions
            ```

            Show the results to the user. If they want to resume a session, suggest:
            ```
            orrery resume <index>
            ```
            """
            try sessionsContent.write(to: sessionsMd, atomically: true, encoding: .utf8)

            let resumeMd = commandsDir.appendingPathComponent("orrery:resume.md")
            let resumeContent = """
            # Resume a session by index

            Resume an AI tool session using its index number from `orrery sessions`.

            Usage: Specify the session index to resume. Additional flags are passed through to the AI tool.

            Example: /orrery:resume 1
            Example: /orrery:resume 2 --dangerously-skip-permissions

            When this command is invoked, run:
            ```
            orrery resume $ARGUMENTS
            ```
            """
            try resumeContent.write(to: resumeMd, atomically: true, encoding: .utf8)

            // Project-local copy of the phantom slash command. The global
            // install at ~/.claude/commands/orrery:phantom.md only applies
            // when CLAUDE_CONFIG_DIR is unset (origin env). For non-origin
            // envs, project-local commands are read regardless of
            // CLAUDE_CONFIG_DIR — this makes /orrery:phantom available in
            // any project where `orrery mcp setup` has been run.
            let phantomMd = commandsDir.appendingPathComponent("orrery:phantom.md")
            try PhantomTriggerCommand.slashCommandMarkdown.write(to: phantomMd, atomically: true, encoding: .utf8)
            let magiMd = commandsDir.appendingPathComponent("orrery:magi.md")
            let magiContent = """
            # Multi-model discussion (Magi)

            Start a multi-model discussion where Claude, Codex, and Gemini debate a topic
            and produce a consensus report.

            Usage: Describe the topic to discuss. Use semicolons to separate sub-topics.

            Example: /orrery:magi Should we use REST or GraphQL for the new API?
            Example: /orrery:magi Performance; Developer experience; Maintenance cost

            When this command is invoked, use the orrery_magi MCP tool with:
            - topic: "$ARGUMENTS"
            - rounds: 1 (default; use more rounds only if the user explicitly asks for deeper discussion)

            If the user requests multiple rounds (e.g. "3 rounds", "deeper discussion"),
            warn them it may take several minutes, then set rounds accordingly.

            After receiving the result, summarize the consensus report for the user,
            highlighting areas of agreement and disagreement.
            """
            try magiContent.write(to: magiMd, atomically: true, encoding: .utf8)

            let specMd = commandsDir.appendingPathComponent("orrery:spec.md")
            let specContent = """
            # Generate spec from discussion

            Generate a structured implementation spec from a Magi consensus report
            or any Markdown discussion document.

            Usage: Provide the path to the input Markdown file.

            Example: /orrery:spec docs/discussions/2026-04-17-my-discussion.md
            Example: /orrery:spec docs/discussions/my-discussion.md --profile minimal

            When this command is invoked, use the orrery_spec MCP tool with:
            - input: the file path from $ARGUMENTS
            - profile: extract from $ARGUMENTS if --profile is specified, otherwise omit
            - review: extract from $ARGUMENTS if --review is specified, otherwise false

            After receiving the result, show the user the generated spec path
            and offer to open or review it.
            """
            try specContent.write(to: specMd, atomically: true, encoding: .utf8)

            let specVerifyMd = commandsDir.appendingPathComponent("orrery:spec-verify.md")
            let specVerifyContent = """
            # Verify a spec's acceptance criteria

            Run the verify phase of a structured spec produced by `orrery spec` /
            `/orrery:spec`. The tool parses the spec's `## 驗收標準` section, then either
            reports every acceptance command as dry-run (default) or executes them under
            a sandbox policy.

            Usage: Provide the path to the spec markdown file.  Append flags verbatim to
            ask for non-default behaviour:

            - `--execute` — actually run sandboxed shell commands
            - `--strict-policy` — treat any `policy_blocked` command as failure
            - `--review` — after a clean verify, spawn one Magi advisory review

            Example: /orrery:spec-verify docs/tasks/2026-04-18-orrery-spec-mcp-tool.md
            Example: /orrery:spec-verify docs/tasks/2026-04-17-magi-extraction.md --execute
            Example: /orrery:spec-verify docs/tasks/foo.md --execute --strict-policy --review

            When this command is invoked, use the orrery_spec_verify MCP tool with:
            - spec_path: the file path from $ARGUMENTS
            - execute: true if --execute appears in $ARGUMENTS, else false
            - strict_policy: true if --strict-policy appears, else false
            - review: true if --review appears, else false

            After receiving the result, summarise for the user:
            - The phase and whether it passed / failed / had policy_blocked entries
            - Any failed commands with their stderr_snippet
            - Any policy_blocked commands (show the reason — do NOT suggest running
              them manually unless the user asks — the block is by design)
            - The review verdict if present, noting it is advisory only

            If the JSON's error field is non-null, show the error and stop — the spec
            is malformed (missing `## 驗收標準`, bad mode, etc.).
            """
            try specVerifyContent.write(to: specVerifyMd, atomically: true, encoding: .utf8)

            let specImplementMd = commandsDir.appendingPathComponent("orrery:spec-implement.md")
            let specImplementContent = """
            # Implement a spec

            Launch a delegate agent (claude-code / codex / gemini) to write code per a structured
            spec produced by `orrery spec` / `/orrery:spec`. The spec MUST contain all four
            mandatory headings: `## 介面合約` / `## 改動檔案` / `## 實作步驟` / `## 驗收標準`;
            missing any → fail-fast error.

            The tool **returns immediately** with a `session_id` + `status: "running"`. Actual
            code-writing happens in a detached subprocess. To observe progress, poll
            `orrery_spec_status` (see `/orrery:spec-status`).

            Usage: Provide the path to the spec. Append optional flags verbatim:

            - `--tool claude|codex|gemini` — delegate CLI (default: first available)
            - `--resume-session-id <uuid>` — resume a prior orrery spec-run session
            - `--timeout <seconds>` — overall timeout for the delegate subprocess (default 3600)

            Example: /orrery:spec-implement docs/tasks/2026-04-20-my-feature.md
            Example: /orrery:spec-implement docs/tasks/foo.md --tool codex --timeout 1800

            When this command is invoked, use the orrery_spec_implement MCP tool with:
            - spec_path: the file path from $ARGUMENTS
            - tool: parse from $ARGUMENTS if `--tool` is provided, else omit
            - resume_session_id: parse from $ARGUMENTS if `--resume-session-id` is provided
            - timeout: parse from $ARGUMENTS if `--timeout` is provided

            After the tool returns (immediately, with status=running), summarise for the user:
            - The session_id (they'll need it to poll status)
            - That the delegate is running in the background
            - The recommended next step: call `/orrery:spec-status <session_id>` after ~2s,
              then ~3s, then ~5s, settling at 30s for long runs

            If the JSON's error field is non-null, show the error and stop — the spec is
            malformed (missing one of the four mandatory headings) or the session could not
            be launched.
            """
            try specImplementContent.write(to: specImplementMd, atomically: true, encoding: .utf8)

            let specStatusMd = commandsDir.appendingPathComponent("orrery:spec-status.md")
            let specStatusContent = """
            # Poll spec-implement status

            Query the status of a running `orrery_spec_implement` session. Safe to call
            repeatedly — reads the persisted state JSON, never mutates anything.

            Usage: Provide the session_id from a prior `/orrery:spec-implement` invocation.
            Append optional flags verbatim:

            - `--include-log` — include the last 50 lines of the progress jsonl in log_tail
            - `--since-timestamp <ISO8601>` — only include log entries after this timestamp

            Example: /orrery:spec-status SID-ABC-123
            Example: /orrery:spec-status SID-ABC-123 --include-log
            Example: /orrery:spec-status SID-ABC-123 --include-log --since-timestamp 2026-04-20T12:00:00Z

            **Polling cadence**: first poll ~2s after implement returns; then exponential
            backoff `min(30s, prev * 1.5)`; after ~5 minutes settle at 30s. Do not poll
            faster than every 2s — that's wasteful and may rate-limit the MCP server.

            When this command is invoked, use the orrery_spec_status MCP tool with:
            - session_id: from $ARGUMENTS
            - include_log: true if `--include-log` appears, else false
            - since_timestamp: parse from $ARGUMENTS if `--since-timestamp` is provided

            After the tool returns, summarise for the user:
            - `status`: running / done / failed / aborted
            - `progress.current_step` if meaningful (failed_step for failed sessions)
            - `diff_summary` and `touched_files` when terminal
            - If status == "failed", show `last_error` and surface the tail of log_tail if
              include_log was used
            - If status == "running", remind the user when the next recommended poll is
            """
            try specStatusContent.write(to: specStatusMd, atomically: true, encoding: .utf8)
        }
    }
}
