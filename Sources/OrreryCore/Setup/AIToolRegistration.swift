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

    /// Tools orrery describes through a plugin process rather than the enum
    /// bridge.
    ///
    /// A tool cannot be both. `registerPlugins` refuses a plugin whose id is
    /// already registered — that rule is what stops a third party displacing a
    /// tool orrery ships, so it must keep refusing. The way claude comes from
    /// `orrery-claude` is therefore for the bridge to stop describing it, not
    /// for the plugin to win a fight over the id.
    ///
    /// The consequence is deliberate: `registerBuiltInTools` alone no longer
    /// produces a complete registry. Completeness needs the plugins too, which
    /// is why a tool whose plugin failed to load must never be recorded as
    /// covered by a one-shot migration.
    public static let pluginProvidedTools: [Tool] = [.claude]

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
    ///
    /// - Parameter providedByPlugin: tools to leave out, because a plugin
    ///   describes them. Injectable rather than read from
    ///   ``pluginProvidedTools`` directly so a test can exercise the
    ///   duplicate-id rule against a tool that really is a built-in — the rule
    ///   is about built-ins in general, not about whichever tool happens to be
    ///   plugin-provided this month.
    public static func registerBuiltInTools(
        into registry: AIToolRegistry,
        providedByPlugin: [Tool] = pluginProvidedTools
    ) throws {
        for tool in Tool.allCases where !providedByPlugin.contains(tool) {
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
        timeout: Duration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        for toolID in toolIDs {
            guard let binary = PluginDiscovery.locate(toolID: toolID, environment: environment)
            else { continue }

            let transport = StdioTransport(
                executable: binary, arguments: [], environment: [:])

            // `connect`'s own timeout is sufficient — the transport's read is
            // cancellable, so nothing external has to intervene.
            //
            // A watchdog used to sit here, terminating the transport after
            // twice the timeout, because a blocking read could not be stopped
            // any other way. It was wrong twice over. It patched one call site
            // while `RemoteAITool.connect` stayed unusable everywhere else, and
            // `try? await Task.sleep` swallows the cancellation it is given, so
            // cancelling the watchdog ran the terminate anyway — every plugin
            // that connected successfully had its process killed the moment it
            // registered. Removing it was the fix; the mechanism belongs in the
            // transport, and now lives there.
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
