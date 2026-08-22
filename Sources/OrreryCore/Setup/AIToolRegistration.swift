import Foundation
import AIToolKit

/// Registers the tools this build ships with.
///
/// No production code reads the registry yet: `AccountMigration`'s five
/// one-shot migrations still derive their tool set from `Tool`, which is total
/// at compile time and so cannot be affected by when this runs. The
/// enum remains the source of truth for this phase; this populates the registry
/// alongside it.
///
/// The ordering nonetheless matters once those call sites move. A registry is
/// total only if registration ran, so a migration that executes before this
/// would see a short tool list, skip whatever was missing, and write its flag
/// anyway — leaving that tool unmigrated on the machine, invisibly and
/// permanently. `main.swift` therefore sequences this above them explicitly
/// now, rather than relying on load order or on someone noticing later.
public enum AIToolRegistration {

    /// Registers into the shared registry. Idempotent.
    ///
    /// Throws whatever the registry refuses. Built-in ids come from
    /// `Tool.rawValue` and are known-valid, so a throw here means a built-in
    /// id has become something a host cannot write down — a bug that must
    /// surface, not be swallowed at the call site.
    public static func registerBuiltInTools() throws {
        try registerBuiltInTools(into: .shared)
    }

    /// Registry taken as a parameter so tests never touch the shared instance.
    public static func registerBuiltInTools(into registry: AIToolRegistry) throws {
        for tool in Tool.allCases {
            try registry.register(tool.aiTool)
        }
    }

    /// Registers any tool plugins found on disk, after the built-ins.
    ///
    /// Built-ins go first deliberately: a plugin that claims an id already
    /// taken cannot displace a tool orrery ships. `AIToolRegistry.register`
    /// itself has no concept of "taken" — it replaces whatever was there — so
    /// this checks `registry.tool(id:)` itself before registering a plugin,
    /// rather than relying on call order alone to keep a malicious or
    /// careless plugin from overwriting a built-in.
    ///
    /// A plugin that is missing, hangs, crashes, speaks an unknown protocol,
    /// or claims an id already registered is skipped with a warning on
    /// stderr — never a thrown error. One broken plugin must not cost the
    /// host its working tools, and that has to be true structurally: every
    /// exit from the loop body other than a clean registration falls through
    /// to the same `continue`, so no future failure mode added to this
    /// function can accidentally propagate past the plugin that hit it.
    ///
    /// `connect` can fail after the child process has already been spawned:
    /// `StdioTransport` is an actor with no `deinit`, so nothing else reaps
    /// that process. Every path out of the `do` block below — success or
    /// failure — terminates the transport it started, except the one where
    /// the tool is handed to the registry and kept alive for the run.
    public static func registerPlugins(
        into registry: AIToolRegistry,
        toolIDs: [String],
        timeout: Duration
    ) async {
        for toolID in toolIDs {
            guard let binary = PluginDiscovery.locate(toolID: toolID) else { continue }

            let transport = StdioTransport(
                executable: binary, arguments: [], environment: [:])
            do {
                let tool = try await RemoteAITool.connect(
                    transport: transport, timeout: timeout)

                guard registry.tool(id: tool.id) == nil else {
                    await transport.terminate()
                    FileHandle.standardError.write(Data(
                        "[orrery] tool plugin '\(toolID)' not loaded: id '\(tool.id)' is already registered\n".utf8))
                    continue
                }

                try registry.register(tool)
            } catch {
                await transport.terminate()
                FileHandle.standardError.write(Data(
                    "[orrery] tool plugin '\(toolID)' not loaded: \(error)\n".utf8))
            }
        }
    }
}
