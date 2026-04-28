import Foundation

/// Declarative install plan for a third-party add-on.
public struct ThirdPartyPackage: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let source: ThirdPartySource
    public let steps: [ThirdPartyStep]

    public init(id: String, displayName: String, description: String,
                source: ThirdPartySource, steps: [ThirdPartyStep]) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.source = source
        self.steps = steps
    }

    /// Returns a copy with the git source URL swapped. No-op for non-git sources.
    public func replacingGitURL(_ newURL: String) -> ThirdPartyPackage {
        guard case .git(_, let ref) = source else { return self }
        return ThirdPartyPackage(
            id: id, displayName: displayName, description: description,
            source: .git(url: newURL, ref: ref), steps: steps
        )
    }
}

public enum ThirdPartySource: Codable, Equatable, Sendable {
    case git(url: String, ref: String)
    case tarball(url: String, sha256: String)       // reserved — not used in v1
    case vendored(bundlePath: String)               // test-only in v1

    private enum TypeKey: String, Codable { case git, tarball, vendored }
    private enum CodingKeys: String, CodingKey { case type, url, ref, sha256, bundlePath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(TypeKey.self, forKey: .type) {
        case .git:
            self = .git(url: try c.decode(String.self, forKey: .url),
                        ref: try c.decode(String.self, forKey: .ref))
        case .tarball:
            self = .tarball(url: try c.decode(String.self, forKey: .url),
                            sha256: try c.decode(String.self, forKey: .sha256))
        case .vendored:
            self = .vendored(bundlePath: try c.decode(String.self, forKey: .bundlePath))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .git(let url, let ref):
            try c.encode(TypeKey.git, forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(ref, forKey: .ref)
        case .tarball(let url, let sha):
            try c.encode(TypeKey.tarball, forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(sha, forKey: .sha256)
        case .vendored(let path):
            try c.encode(TypeKey.vendored, forKey: .type)
            try c.encode(path, forKey: .bundlePath)
        }
    }
}

public enum ThirdPartyStep: Codable, Equatable, Sendable {
    case copyFile(from: String, to: String)
    case copyGlob(from: String, toDir: String)
    case patchSettings(file: String, patch: JSONValue)

    private enum TypeKey: String, Codable { case copyFile, copyGlob, patchSettings }
    private enum CodingKeys: String, CodingKey { case type, from, to, toDir, file, patch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(TypeKey.self, forKey: .type) {
        case .copyFile:
            self = .copyFile(from: try c.decode(String.self, forKey: .from),
                             to: try c.decode(String.self, forKey: .to))
        case .copyGlob:
            self = .copyGlob(from: try c.decode(String.self, forKey: .from),
                             toDir: try c.decode(String.self, forKey: .toDir))
        case .patchSettings:
            self = .patchSettings(file: try c.decode(String.self, forKey: .file),
                                  patch: try c.decode(JSONValue.self, forKey: .patch))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .copyFile(let f, let t):
            try c.encode(TypeKey.copyFile, forKey: .type)
            try c.encode(f, forKey: .from); try c.encode(t, forKey: .to)
        case .copyGlob(let f, let d):
            try c.encode(TypeKey.copyGlob, forKey: .type)
            try c.encode(f, forKey: .from); try c.encode(d, forKey: .toDir)
        case .patchSettings(let f, let p):
            try c.encode(TypeKey.patchSettings, forKey: .type)
            try c.encode(f, forKey: .file); try c.encode(p, forKey: .patch)
        }
    }
}
