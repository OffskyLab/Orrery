import ArgumentParser
import Foundation

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
        let claudeCommandsDir = userHomeURL()
            .appendingPathComponent(".claude")
            .appendingPathComponent("commands")
        do {
            try FileManager.default.createDirectory(at: claudeCommandsDir, withIntermediateDirectories: true)
        } catch {
            stderrWrite(L10n.Setup.failedToWrite(claudeCommandsDir.path, error.localizedDescription))
            return
        }

        let phantomMd = claudeCommandsDir.appendingPathComponent("orrery:phantom.md")
        do {
            try PhantomSupport.slashCommandMarkdown.write(to: phantomMd, atomically: true, encoding: .utf8)
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
        let home = userHomeURL()
        switch shell {
        case "bash": return home.appendingPathComponent(".bashrc")
        default:     return home.appendingPathComponent(".zshrc")
        }
    }

    static func activateFile() -> URL {
        orreryHomeURL().appendingPathComponent("activate.sh")
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

        // Take over any tool whose config dir exists and isn't already managed.
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

        // origin defaults to fully shared — no interactive prompts. Its memory
        // and sessions must be available to any sandbox that opts into sharing;
        // if origin kept them isolated, a sandbox set to "shared" would have
        // nothing to share with.
        var config = store.loadOriginWorkspace()
        config.isolateMemory = false
        for tool in newlyTakenOver {
            config.isolatedSessionTools.remove(tool)
            try? store.ensureSharedSessionLinksForOrigin(tool: tool)
        }
        try? store.saveOriginWorkspace(config)

        stderrWrite("\n\(L10n.Setup.originHeader)\n")
        stderrWrite("\(L10n.Setup.originSharedDefault)\n")
    }

    static func installShellIntegration(to url: URL, activatePath: String) {
        // Eager, unconditional source: activate.sh defines `orrery()`,
        // `claude()`, and `gemini()`. A previous "lazy bootstrap" shape only
        // ever stubbed `orrery()` in the rc file, and left `claude()`/
        // `gemini()` undefined until `orrery` itself had been invoked at
        // least once in the shell session — so a brand-new shell where the
        // user ran bare `claude` before ever running `orrery` got the raw,
        // unwrapped binary on PATH, silently bypassing phantom supervision
        // (and gemini's HOME-wrapper account isolation) entirely. Sourcing
        // directly closes that gap: every function activate.sh defines is
        // available from the very first prompt, no bootstrap trigger needed.
        //
        // The existence check guards the case where `~/.orrery` was removed
        // (or moved) without re-running `orrery setup` — better to silently
        // skip orrery integration for that shell than print a "no such
        // file" error on every single prompt.
        //
        // Cost accepted: every new shell now pays activate.sh's own startup
        // work (`_orrery_init`'s version-stamp check shells out to
        // `orrery-bin --version`), not just shells that actually invoke
        // `orrery`. That's a deliberate trade against the silent-bypass
        // failure mode above.
        let stubMarker = "# orrery shell integration (source)"
        let stub = """
        \(stubMarker)
        if [ -f "\(activatePath)" ]; then
          source "\(activatePath)"
        fi
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
    /// Handles the four shapes we've shipped:
    ///   1. `# orrery shell integration\nsource "…/activate.sh"`       (pre-stub)
    ///   2. `eval "$(orrery setup)"`                                   (oldest)
    ///   3. `# orrery shell integration (lazy bootstrap)\norrery() { … }` (orrery()-only stub)
    ///   4. `# orrery shell integration (source)\nif [ -f … ]; then … fi` (current)
    /// Any trailing blank lines left behind are collapsed by the caller.
    static func stripOrreryBlocks(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Shape 4: eager-source — comment + `if [ -f … ]; then … fi` guard
            if line.trimmingCharacters(in: .whitespaces) == "# orrery shell integration (source)" {
                i += 1
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "fi" {
                    i += 1
                }
                if i < lines.count { i += 1 } // consume closing `fi`
                continue
            }
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
