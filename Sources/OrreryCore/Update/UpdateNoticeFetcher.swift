import Foundation

struct SemanticVersion: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ string: String) {
        let core = string.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? string
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct VersionConstraint: Equatable {
    enum Operator: Equatable {
        case lt, lte, eq, gte, gt
    }

    let op: Operator
    let version: SemanticVersion

    init(op: Operator, version: SemanticVersion) {
        self.op = op
        self.version = version
    }

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Order matters: longer prefixes first
        let prefixes: [(String, Operator)] = [
            ("<=", .lte), (">=", .gte), ("<", .lt), (">", .gt), ("=", .eq)
        ]
        for (prefix, op) in prefixes where trimmed.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard let version = SemanticVersion(rest) else { return nil }
            self.op = op
            self.version = version
            return
        }
        return nil
    }

    func isSatisfied(by current: SemanticVersion) -> Bool {
        switch op {
        case .lt:  return current <  version
        case .lte: return current <= version
        case .eq:  return current == version
        case .gte: return current >= version
        case .gt:  return current >  version
        }
    }
}
