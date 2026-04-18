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

struct NoticeCache {
    struct Entry: Codable, Equatable {
        let etag: String?
        let body: String
        let appliesToRaw: String
        let fetchedAt: Int

        enum CodingKeys: String, CodingKey {
            case etag
            case body
            case appliesToRaw = "applies_to"
            case fetchedAt = "fetched_at"
        }
    }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    func read() -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func write(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entry) else { return }
        // Ensure parent directory exists — callers may pass a path under
        // $ORRERY_HOME which exists, but tests pass temporaryDirectory too.
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum FetchResult {
    case ok(etag: String?, body: String)
    case notModified
    case gone
    case failed
}

struct UpdateNoticeFetcher {
    static let maxBodyBytes = 64 * 1024

    let url: URL
    let cacheURL: URL
    let transport: @Sendable (URL, String?) -> FetchResult

    func fetch(currentVersion: SemanticVersion) -> String? {
        let cache = NoticeCache(url: cacheURL)
        let existing = cache.read()

        let result = transport(url, existing?.etag)

        switch result {
        case .ok(let etag, let body):
            guard body.utf8.count <= Self.maxBodyBytes else { return nil }
            guard let notice = UpdateNotice.parse(body) else { return nil }
            let appliesToRaw = notice.constraints
                .map { formatConstraint($0) }
                .joined(separator: ", ")
            cache.write(.init(
                etag: etag,
                body: notice.body,
                appliesToRaw: appliesToRaw,
                fetchedAt: Int(Date().timeIntervalSince1970)
            ))
            return notice.applies(to: currentVersion) ? notice.body : nil

        case .notModified:
            guard let cached = existing else { return nil }
            return renderFromCache(cached, current: currentVersion)

        case .gone:
            cache.delete()
            return nil

        case .failed:
            guard let cached = existing else { return nil }
            return renderFromCache(cached, current: currentVersion)
        }
    }

    private func renderFromCache(_ entry: NoticeCache.Entry, current: SemanticVersion) -> String? {
        let parts = entry.appliesToRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var constraints: [VersionConstraint] = []
        for part in parts {
            guard let c = VersionConstraint(part) else { return nil }
            constraints.append(c)
        }
        guard constraints.allSatisfy({ $0.isSatisfied(by: current) }) else { return nil }
        return entry.body
    }

    private func formatConstraint(_ c: VersionConstraint) -> String {
        let opStr: String
        switch c.op {
        case .lt:  opStr = "<"
        case .lte: opStr = "<="
        case .eq:  opStr = "="
        case .gte: opStr = ">="
        case .gt:  opStr = ">"
        }
        return "\(opStr)\(c.version.major).\(c.version.minor).\(c.version.patch)"
    }
}

extension UpdateNoticeFetcher {
    /// Default production configuration: fetches from the repo's main branch
    /// and caches under $ORRERY_HOME/.update-notice-cache.json.
    static func production() -> UpdateNoticeFetcher {
        let defaultURL = URL(string: "https://raw.githubusercontent.com/OffskyLab/Orrery/main/docs/update-notice.md")!
        return UpdateNoticeFetcher(
            url: defaultURL,
            cacheURL: Self.defaultCacheURL(),
            transport: Self.curlTransport
        )
    }

    static func defaultCacheURL() -> URL {
        let home: URL
        if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            home = URL(fileURLWithPath: custom)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orrery")
        }
        return home.appendingPathComponent(".update-notice-cache.json")
    }

    static let curlTransport: @Sendable (URL, String?) -> FetchResult = { url, etag in
        let tmp = FileManager.default.temporaryDirectory
        let bodyFile = tmp.appendingPathComponent("orrery-notice-body-\(UUID().uuidString)")
        let hdrFile = tmp.appendingPathComponent("orrery-notice-hdr-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: bodyFile)
            try? FileManager.default.removeItem(at: hdrFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = [
            "curl", "-s", "--max-time", "5",
            "-D", hdrFile.path,
            "-o", bodyFile.path,
            "-w", "%{http_code}",
            "-H", "User-Agent: orrery-cli",
        ]
        if let etag = etag {
            args.append("-H")
            args.append("If-None-Match: \(etag)")
        }
        args.append(url.absoluteString)
        process.arguments = args

        let statusPipe = Pipe()
        process.standardOutput = statusPipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return .failed }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .failed }

        let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
        let statusStr = String(data: statusData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let status = Int(statusStr) else { return .failed }

        switch status {
        case 200:
            guard let body = try? String(contentsOf: bodyFile, encoding: .utf8) else {
                return .failed
            }
            let responseEtag = parseEtag(fromHeaderFile: hdrFile)
            return .ok(etag: responseEtag, body: body)
        case 304: return .notModified
        case 404: return .gone
        default:  return .failed
        }
    }

    private static func parseEtag(fromHeaderFile url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Use the LAST ETag line — if curl followed redirects, earlier headers
        // belong to redirect responses rather than the final 200.
        var latest: String? = nil
        for line in text.components(separatedBy: "\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("etag:") else { continue }
            let value = line.dropFirst("etag:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { latest = value }
        }
        return latest
    }
}
