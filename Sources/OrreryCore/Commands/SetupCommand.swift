import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: L10n.Setup.abstract
    )

    @Option(name: .long, help: ArgumentHelp(L10n.Setup.shellHelp))
    public var shell: String?

    public init() {}

    public func run() throws {
        let resolved = try Self.resolveShell(explicit: shell)
        let rcFile = Self.rcFile(for: resolved)
        let activateFile = Self.activateFile()

        // 1. Generate activate.sh
        Self.writeActivateScript(to: activateFile)

        // 2. Add source line to rc file
        Self.installShellIntegration(to: rcFile, activatePath: activateFile.path)

        // 3. Install global slash commands available in every project
        Self.installGlobalSlashCommands()

        // 4. Offer origin takeover (interactive, skipped when /dev/tty unavailable)
        Self.offerOriginTakeover()
    }

    /// Install slash commands that should be available in every project (not just
    /// where `orrery mcp setup` has been run). Currently just `orrery:phantom`.
    static func installGlobalSlashCommands() {
        let claudeCommandsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("commands")
        do {
            try FileManager.default.createDirectory(at: claudeCommandsDir, withIntermediateDirectories: true)
        } catch {
            stderrWrite(L10n.Setup.failedToWrite(claudeCommandsDir.path, error.localizedDescription))
            return
        }

        let phantomMd = claudeCommandsDir.appendingPathComponent("orrery:phantom.md")
        let phantomContent = """
        ---
        description: Switch orrery environment without restarting Claude
        argument-hint: [env-name]
        ---

        # Phantom: switch orrery environment in-place

        Switch the active orrery environment without losing the conversation. Claude exits and the orrery supervisor relaunches it with the new env active and `--resume`, so the conversation continues where it left off.

        **Prerequisite**: Claude must have been launched via `orrery run claude` (which is phantom-supervised by default). If Claude was launched directly or with `orrery run --non-phantom claude`, the trigger will error with a clear message.

        ## What to do

        Inspect `$ARGUMENTS`:

        - **If `$ARGUMENTS` is non-empty** (a target env name): run `orrery-bin _phantom-trigger $ARGUMENTS`. The trigger writes a sentinel and signals Claude to exit. The supervisor relaunches Claude under the new env automatically — no further user action is needed.

        - **If `$ARGUMENTS` is empty**: first run `orrery-bin _phantom-trigger` (with no arguments) to get the list of available environments. Then ask the user which environment they want to switch to — present the list as choices. Once they answer, run `orrery-bin _phantom-trigger <chosen-env>`.

        Do not narrate the relaunch — Claude will simply exit and reappear with the new env. The user's next message lands in the new env.
        """
        do {
            try phantomContent.write(to: phantomMd, atomically: true, encoding: .utf8)
            stderrWrite(L10n.Setup.installedSlashCommand(phantomMd.path))
        } catch {
            stderrWrite(L10n.Setup.failedToWrite(phantomMd.path, error.localizedDescription))
        }
    }

    static func resolveShell(explicit: String?) throws -> String {
        if let explicit {
            let lower = explicit.lowercased()
            guard lower == "bash" || lower == "zsh" else {
                throw ValidationError(L10n.Setup.unsupportedShell(explicit))
            }
            return lower
        }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = URL(fileURLWithPath: shellPath).lastPathComponent
        switch name {
        case "bash": return "bash"
        case "zsh":  return "zsh"
        default:     return "zsh"
        }
    }

    static func rcFile(for shell: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch shell {
        case "bash": return home.appendingPathComponent(".bashrc")
        default:     return home.appendingPathComponent(".zshrc")
        }
    }

    static func activateFile() -> URL {
        let home: URL
        if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            home = URL(fileURLWithPath: custom)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orrery")
        }
        return home.appendingPathComponent("activate.sh")
    }

    static func writeActivateScript(to url: URL) {
        let content = ShellFunctionGenerator.generate()
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            stderrWrite(L10n.Setup.wroteActivate(url.path))
        } catch {
            stderrWrite(L10n.Setup.failedToWrite(url.path, error.localizedDescription))
        }
    }

    static func offerOriginTakeover() {
        let store = EnvironmentStore.default
        store.setOriginTakeoverOptOut(false)

        // Only show prompts for tools taken over during THIS run (not previously managed ones).
        var newlyTakenOver: [Tool] = []
        for tool in Tool.allCases {
            guard !store.isOriginManaged(tool: tool),
                  FileManager.default.fileExists(atPath: tool.defaultConfigDir.path)
            else { continue }
            if (try? store.originTakeover(tool: tool)) != nil {
                stderrWrite(L10n.Origin.tookOver(tool.rawValue, store.originConfigDir(tool: tool).path) + "\n")
                newlyTakenOver.append(tool)
            }
        }

        guard !newlyTakenOver.isEmpty else { return }

        // Interactive prompts only when /dev/tty is available
        let ttyCheck = open("/dev/tty", O_RDWR)
        guard ttyCheck >= 0 else { return }
        close(ttyCheck)

        var config = store.loadOriginConfig()

        stderrWrite("\n\(L10n.Setup.originHeader)\n")

        // For each newly taken-over tool: ask session then memory; summaries stay visible
        for tool in newlyTakenOver {
            stderrWrite("\n  \(tool.coloredTag)\n")

            // --- Session ---
            let sessionPicker = SingleSelect(
                title: L10n.Create.sessionSharePrompt,
                options: [L10n.Create.sessionShareYes, L10n.Create.sessionShareNo],
                selected: 0
            )
            let isolateSession = sessionPicker.run() == 1
            if isolateSession {
                config.isolatedSessionTools.insert(tool)
            } else {
                config.isolatedSessionTools.remove(tool)
                try? store.ensureSharedSessionLinksForOrigin(tool: tool)
            }
            stderrWrite("    \(L10n.Create.sessions(isolateSession))\n")

            // --- Memory (Claude only — codex/gemini have no memory concept) ---
            if tool == .claude {
                let memoryPicker = SingleSelect(
                    title: L10n.Create.memorySharePrompt,
                    options: [L10n.Create.memoryShareYes, L10n.Create.memoryShareNo],
                    selected: 1   // default: 不共享 (isolate)
                )
                config.isolateMemory = memoryPicker.run() == 1
                stderrWrite("    \(L10n.Create.memory(config.isolateMemory))\n")
            }
        }

        try? store.saveOriginConfig(config)
    }

    static func installShellIntegration(to url: URL, activatePath: String) {
        // Lazy-bootstrap stub: defines `orrery()` as a one-liner that sources
        // activate.sh (which overwrites the function with the real one) and
        // re-invokes it. The second `orrery "$@"` lookup resolves to the newly
        // defined function because function names are resolved at call time.
        //
        // Why stub instead of `source activate.sh`:
        //   1. Shell startup stays fast — activate.sh is only loaded when the
        //      user actually invokes `orrery`.
        //   2. Since the binary was renamed `orrery-bin`, calling `orrery`
        //      MUST go through the shell function. A stub guarantees one is
        //      always defined, even before activate.sh is sourced.
        let stubMarker = "# orrery shell integration (lazy bootstrap)"
        let stub = """
        \(stubMarker)
        orrery() {
          source "\(activatePath)"
          orrery "$@"
        }
        """

        var existing = ""
        if FileManager.default.fileExists(atPath: url.path) {
            existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        // Strip every pre-existing orrery block so the final rc file contains
        // exactly one authoritative stub. Catches both legacy shapes:
        //   - "# orrery shell integration\nsource \".../activate.sh\""
        //   - `eval "$(orrery setup)"`
        // and any previous lazy-bootstrap block (even with a stale activatePath).
        let hadPrevious = containsOrreryBlock(existing)
        let cleaned = stripOrreryBlocks(existing)

        // Fresh append of the canonical stub.
        var trailing = cleaned
        while trailing.hasSuffix("\n\n") { trailing.removeLast() }
        let appended = trailing + (trailing.hasSuffix("\n") ? "\n" : "\n\n") + stub + "\n"

        do {
            try appended.write(to: url, atomically: true, encoding: .utf8)
            if hadPrevious {
                stderrWrite(L10n.Setup.migratedRc(url.path))
            } else {
                stderrWrite(L10n.Setup.addedTo(url.path))
            }
        } catch {
            stderrWrite(L10n.Setup.failedToWrite(url.path, error.localizedDescription))
        }
    }

    /// True when `text` contains at least one orrery-integration block in any
    /// of the known shapes.
    static func containsOrreryBlock(_ text: String) -> Bool {
        text.contains("# orrery shell integration") || text.contains(#"eval "$(orrery setup)""#)
    }

    /// Remove every legacy / stale orrery integration block from `text`.
    /// Handles the three shapes we've shipped:
    ///   1. `# orrery shell integration\nsource "…/activate.sh"`       (pre-stub)
    ///   2. `eval "$(orrery setup)"`                                   (oldest)
    ///   3. `# orrery shell integration (lazy bootstrap)\norrery() { … }` (current)
    /// Any trailing blank lines left behind are collapsed by the caller.
    static func stripOrreryBlocks(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Shape 3: lazy-bootstrap — comment + function body + closing brace
            if line.trimmingCharacters(in: .whitespaces) == "# orrery shell integration (lazy bootstrap)" {
                i += 1
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "}" {
                    i += 1
                }
                if i < lines.count { i += 1 } // consume closing brace
                continue
            }
            // Shape 1: plain source line under the legacy comment header
            if line.trimmingCharacters(in: .whitespaces) == "# orrery shell integration" {
                i += 1
                // consume the single source line (and any trailing continuation)
                while i < lines.count
                    && (lines[i].contains("source") && lines[i].contains("activate.sh")) {
                    i += 1
                }
                continue
            }
            // Shape 2: one-liner eval
            if line.contains(#"eval "$(orrery setup)""#) {
                i += 1
                continue
            }
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }
}
