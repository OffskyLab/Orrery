import Testing
import Foundation
@testable import OrreryCore

@Suite("RelativeTime")
struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("seconds bucket")
    func seconds() {
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-5),  now: now) == "5s ago")
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-59), now: now) == "59s ago")
    }

    @Test("minutes bucket")
    func minutes() {
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-60),    now: now) == "1m ago")
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-59*60), now: now) == "59m ago")
    }

    @Test("hours bucket")
    func hours() {
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-60*60),    now: now) == "1h ago")
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-23*60*60), now: now) == "23h ago")
    }

    @Test("days, months, years")
    func longer() {
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-2*86400),    now: now) == "2d ago")
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-45*86400),   now: now) == "1mo ago")
        #expect(RelativeTime.ago(from: now.addingTimeInterval(-400*86400),  now: now) == "1y ago")
    }

    @Test("future dates clamp to 0s")
    func future() {
        #expect(RelativeTime.ago(from: now.addingTimeInterval(60), now: now) == "0s ago")
    }
}
