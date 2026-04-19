import Foundation

public struct InstallRecord: Codable, Equatable, Sendable {
    public let packageID: String
    public let resolvedRef: String
    public let manifestRef: String
    public let installedAt: Date
    public let copiedFiles: [String]
    public let patchedSettings: [SettingsPatchRecord]

    public init(packageID: String, resolvedRef: String, manifestRef: String,
                installedAt: Date, copiedFiles: [String],
                patchedSettings: [SettingsPatchRecord]) {
        self.packageID = packageID
        self.resolvedRef = resolvedRef
        self.manifestRef = manifestRef
        self.installedAt = installedAt
        self.copiedFiles = copiedFiles
        self.patchedSettings = patchedSettings
    }
}

public struct SettingsPatchRecord: Codable, Equatable, Sendable {
    public let file: String
    public let entries: [Entry]

    public init(file: String, entries: [Entry]) {
        self.file = file
        self.entries = entries
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let keyPath: [String]
        public let before: BeforeState
        public init(keyPath: [String], before: BeforeState) {
            self.keyPath = keyPath
            self.before = before
        }
    }

    public enum BeforeState: Codable, Equatable, Sendable {
        case absent
        case scalar(previous: JSONValue)
        case object(addedKeys: [String])
        case array(appendedElements: [JSONValue])

        private enum Kind: String, Codable { case absent, scalar, object, array }
        private enum Keys: String, CodingKey {
            case kind, previous, addedKeys, appendedElements
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .absent:
                self = .absent
            case .scalar:
                self = .scalar(previous: try c.decode(JSONValue.self, forKey: .previous))
            case .object:
                self = .object(addedKeys: try c.decode([String].self, forKey: .addedKeys))
            case .array:
                self = .array(appendedElements: try c.decode([JSONValue].self, forKey: .appendedElements))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .absent:
                try c.encode(Kind.absent, forKey: .kind)
            case .scalar(let v):
                try c.encode(Kind.scalar, forKey: .kind)
                try c.encode(v, forKey: .previous)
            case .object(let keys):
                try c.encode(Kind.object, forKey: .kind)
                try c.encode(keys, forKey: .addedKeys)
            case .array(let els):
                try c.encode(Kind.array, forKey: .kind)
                try c.encode(els, forKey: .appendedElements)
            }
        }
    }
}
