import Foundation

/// Strongly-typed errors emitted by `SpecRunStateReader` / writer code paths.
/// Existing call sites that catch generic `Error` keep working; new code
/// can pattern-match for fine-grained handling (e.g. concurrent resume guard
/// catching `.sessionAlreadyExists`).
public enum SpecRunStateError: Error, LocalizedError {
    case sessionNotFound(String)
    case sessionAlreadyExists(String)
    case ioError(Int32)
    case lockFailed(Int32)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "Spec-run session not found: \(id)"
        case .sessionAlreadyExists(let id):
            return "Spec-run session already exists: \(id)"
        case .ioError(let code):
            return "Spec-run state I/O error (errno=\(code))"
        case .lockFailed(let code):
            return "Failed to acquire spec-run state lock (errno=\(code))"
        case .unsupportedVersion(let v):
            return "Unsupported SpecRunState schema version: \(v) (supported: \(SpecRunStateContract.supportedVersions))"
        }
    }
}

/// Schema-version contract for `~/.orrery/spec-runs/{id}.json`.
///
/// `currentVersion` is what writers stamp; `supportedVersions` is what
/// readers accept. `upgrade(_:)` is the migration hook — for v1 it is the
/// identity, but later schema bumps drop their migration logic here so call
/// sites never change.
public enum SpecRunStateContract {
    public static let currentVersion: Int = 1
    public static let supportedVersions: ClosedRange<Int> = 1...1

    @discardableResult
    public static func upgrade(_ state: SpecRunState) throws -> SpecRunState {
        guard supportedVersions.contains(state.version) else {
            throw SpecRunStateError.unsupportedVersion(state.version)
        }
        return state
    }
}
