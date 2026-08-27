import Foundation

/// Finds a tool plugin binary, in the same order `orrery-sync` is found:
/// an explicit env var, then orrery's own tools directory, then PATH.
///
/// A path that exists but is not executable is ignored rather than trusted —
/// an operator who points the variable at the wrong file should get "no
/// plugin", not a spawn failure deep in a later call.
public enum PluginDiscovery {

    public static func envVarName(toolID: String) -> String {
        "ORRERY_\(toolID.uppercased())_PATH"
    }

    public static func locate(
        toolID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fm = FileManager.default

        if let explicit = environment[envVarName(toolID: toolID)],
           fm.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }

        // Both halves come from the injected `environment`. Taking ORRERY_HOME
        // from the caller and then the home from the real process was the
        // inconsistency worth fixing: a caller that passed an environment
        // *without* ORRERY_HOME — which the tests here do — silently searched the
        // developer's real ~/.orrery/tools, where an installed plugin would be
        // found and mistaken for the fixture.
        let home = environment["ORRERY_HOME"]
            ?? (environment["ORRERY_USER_HOME"].map { URL(fileURLWithPath: $0) } ?? userHomeURL())
                .appendingPathComponent(".orrery").path
        let local = home + "/tools/orrery-\(toolID)"
        if fm.isExecutableFile(atPath: local) {
            return URL(fileURLWithPath: local)
        }

        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(dir) + "/orrery-\(toolID)"
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }
}
