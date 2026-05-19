import Foundation

/// One usage window from Anthropic's `/api/oauth/usage` (e.g. five-hour, seven-day).
public struct WindowedUsage: Codable, Equatable, Sendable {
    /// Percentage in [0, 100]. The API already returns it pre-multiplied.
    public let utilization: Double
    /// When the window resets. `null` in the API when no usage has accrued yet.
    public let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.utilization = try c.decode(Double.self, forKey: .utilization)
        // Server sends ISO 8601 with fractional seconds. JSONDecoder's
        // built-in iso8601 strategy is per-decoder, so parse manually here
        // to keep decoding the rest of the response with default settings.
        // ISO8601DateFormatter is not Sendable — instantiate per-call.
        if let s = try c.decodeIfPresent(String.self, forKey: .resetsAt) {
            self.resetsAt = WindowedUsage.parseISO8601(s)
        } else {
            self.resetsAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(utilization, forKey: .utilization)
        if let resetsAt {
            try c.encode(WindowedUsage.formatISO8601(resetsAt), forKey: .resetsAt)
        } else {
            try c.encodeNil(forKey: .resetsAt)
        }
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    private static func formatISO8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// Snapshot of one tool's quota — currently only Claude exposes a usable
/// endpoint, so this struct mirrors `/api/oauth/usage` directly. Codex and
/// Gemini will get their own variants in P3.
public struct UsageQuota: Codable, Equatable, Sendable {
    public let fiveHour: WindowedUsage?
    public let sevenDay: WindowedUsage?
    /// `seven_day_opus` / `seven_day_sonnet` only present on max plans.
    public let sevenDayOpus: WindowedUsage?
    public let sevenDaySonnet: WindowedUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour       = "five_hour"
        case sevenDay       = "seven_day"
        case sevenDayOpus   = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    public init(
        fiveHour: WindowedUsage?,
        sevenDay: WindowedUsage?,
        sevenDayOpus: WindowedUsage? = nil,
        sevenDaySonnet: WindowedUsage? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
    }
}

/// One cache entry: a quota snapshot plus when we fetched it. Persisted as
/// `~/.orrery/quota-cache/<env-id>.json` keyed by tool.
public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let claude: UsageQuota?

    public init(fetchedAt: Date, claude: UsageQuota? = nil) {
        self.fetchedAt = fetchedAt
        self.claude = claude
    }
}
