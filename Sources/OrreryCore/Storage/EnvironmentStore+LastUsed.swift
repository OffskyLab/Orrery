import Foundation

extension EnvironmentStore {
    /// Newest mtime among the tool's session subdirectories for an environment.
    /// `origin` resolves to the system tool config dir. Returns nil when no
    /// session files have been written yet.
    public func lastUsed(tool: Tool, environment envName: String) -> Date? {
        let configDir = envName == ReservedEnvironment.defaultName
            ? originConfigDir(tool: tool)
            : toolConfigDir(tool: tool, environment: envName)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        var newest: Date?

        for sub in tool.sessionSubdirectories {
            // Sessions subdirs are usually symlinks (shared sessions mode).
            // FileManager.enumerator(at:) refuses to enumerate when the root
            // itself is a symlink — resolve to the real path first.
            let dir = configDir.appendingPathComponent(sub).resolvingSymlinksInPath()
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true,
                      let mtime = values?.contentModificationDate
                else { continue }
                if newest == nil || mtime > newest! { newest = mtime }
            }
        }
        return newest
    }
}
