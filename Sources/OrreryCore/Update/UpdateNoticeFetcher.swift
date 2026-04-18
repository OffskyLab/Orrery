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

struct UpdateNotice: Equatable {
    let constraints: [VersionConstraint]
    let body: String

    static func parse(_ raw: String) -> UpdateNotice? {
        // Normalize CRLF → LF so split on "\n" works
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }

        // Find the closing `---` on its own line, starting from line 1
        var closingIndex: Int? = nil
        for i in 1..<lines.count where lines[i] == "---" {
            closingIndex = i
            break
        }
        guard let closing = closingIndex else { return nil }

        // Header is lines 1..<closing; body is lines closing+1..<end
        var appliesToRaw: String? = nil
        for line in lines[1..<closing] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "applies-to" {
                    appliesToRaw = value
                }
            }
        }
        guard let rawConstraint = appliesToRaw else { return nil }

        // Parse comma-separated constraints
        let parts = rawConstraint.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var constraints: [VersionConstraint] = []
        for part in parts {
            guard let c = VersionConstraint(part) else { return nil }
            constraints.append(c)
        }
        guard !constraints.isEmpty else { return nil }

        let bodyLines = lines[(closing + 1)...]
        // Trim trailing empty lines for tidier output; leading newline is kept lean
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return UpdateNotice(constraints: constraints, body: body)
    }

    func applies(to current: SemanticVersion) -> Bool {
        constraints.allSatisfy { $0.isSatisfied(by: current) }
    }
}
