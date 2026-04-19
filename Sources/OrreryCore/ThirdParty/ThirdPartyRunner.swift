import Foundation

public enum ThirdPartyError: Error, LocalizedError {
    case packageNotFound(id: String)
    case alreadyInstalled(id: String)
    case notInstalled(id: String)
    case envNotFound(String)
    case sourceFetchFailed(reason: String)
    case stepFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .packageNotFound(let id): return "Unknown third-party package: \(id)"
        case .alreadyInstalled(let id): return "\(id) is already installed in this env"
        case .notInstalled(let id): return "\(id) is not installed in this env"
        case .envNotFound(let name): return "Environment '\(name)' not found"
        case .sourceFetchFailed(let r): return "Source fetch failed: \(r)"
        case .stepFailed(let r): return "Install step failed: \(r)"
        }
    }
}

public protocol ThirdPartyRunner: Sendable {
    func install(_ pkg: ThirdPartyPackage,
                 into env: String,
                 refOverride: String?,
                 forceRefresh: Bool) throws -> InstallRecord
    func uninstall(packageID: String, from env: String) throws
    func listInstalled(in env: String) throws -> [InstallRecord]
}

public protocol ThirdPartyRegistry: Sendable {
    func lookup(_ id: String) throws -> ThirdPartyPackage
    func listAvailable() -> [String]
}
