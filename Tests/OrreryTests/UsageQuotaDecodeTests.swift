import Testing
import Foundation
@testable import OrreryCore

@Suite("UsageQuota — /api/oauth/usage decode")
struct UsageQuotaDecodeTests {
    /// Real response shape captured from api.anthropic.com (with values trimmed).
    private let realPayload = #"""
    {
      "five_hour": {"utilization": 0.0, "resets_at": null},
      "seven_day": {"utilization": 13.0, "resets_at": "2026-05-02T18:00:00.808561+00:00"},
      "seven_day_oauth_apps": null,
      "seven_day_opus": null,
      "seven_day_sonnet": {"utilization": 10.0, "resets_at": "2026-05-02T18:00:00.808573+00:00"},
      "seven_day_cowork": null,
      "extra_usage": {"is_enabled": true, "monthly_limit": null, "used_credits": 1108.0}
    }
    """#

    @Test("decodes the live shape including null windows and ISO-8601 fractional seconds")
    func realShape() throws {
        let q = try JSONDecoder().decode(UsageQuota.self, from: Data(realPayload.utf8))
        #expect(q.fiveHour?.utilization == 0.0)
        #expect(q.fiveHour?.resetsAt == nil)
        #expect(q.sevenDay?.utilization == 13.0)
        #expect(q.sevenDay?.resetsAt != nil)
        #expect(q.sevenDayOpus == nil)
        #expect(q.sevenDaySonnet?.utilization == 10.0)
    }

    @Test("round-trips through JSONEncoder")
    func encodeRoundTrip() throws {
        let q = UsageQuota(
            fiveHour: WindowedUsage(utilization: 5.0, resetsAt: Date(timeIntervalSince1970: 1_777_500_000)),
            sevenDay: WindowedUsage(utilization: 25.5, resetsAt: nil)
        )
        let data = try JSONEncoder().encode(q)
        let again = try JSONDecoder().decode(UsageQuota.self, from: data)
        #expect(again.fiveHour?.utilization == 5.0)
        #expect(again.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_777_500_000))
        #expect(again.sevenDay?.resetsAt == nil)
    }
}
