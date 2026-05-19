import Testing
import Foundation
@testable import OrreryCore

@Suite("QuotaCache")
struct QuotaCacheTests {
    private func tempCache() -> (QuotaCache, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-quota-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (QuotaCache(homeURL: home), home)
    }

    @Test("load returns nil when file does not exist")
    func loadMissing() {
        let (cache, _) = tempCache()
        #expect(cache.load(envName: "work") == nil)
    }

    @Test("save then load round-trips a quota snapshot")
    func roundTrip() throws {
        let (cache, _) = tempCache()
        let resetAt = Date(timeIntervalSince1970: 1_777_500_000)
        let quota = UsageQuota(
            fiveHour: WindowedUsage(utilization: 12.5, resetsAt: resetAt),
            sevenDay: WindowedUsage(utilization: 33.0, resetsAt: nil)
        )
        try cache.update(envName: "work", claude: quota,
                         fetchedAt: Date(timeIntervalSince1970: 1_777_400_000))

        let loaded = cache.load(envName: "work")
        #expect(loaded != nil)
        #expect(loaded?.claude?.fiveHour?.utilization == 12.5)
        #expect(loaded?.claude?.fiveHour?.resetsAt == resetAt)
        #expect(loaded?.claude?.sevenDay?.utilization == 33.0)
        #expect(loaded?.claude?.sevenDay?.resetsAt == nil)
        #expect(loaded?.fetchedAt == Date(timeIntervalSince1970: 1_777_400_000))
    }

    @Test("envs are isolated — saving 'work' does not change 'personal'")
    func isolation() throws {
        let (cache, _) = tempCache()
        let q = UsageQuota(fiveHour: WindowedUsage(utilization: 1, resetsAt: nil), sevenDay: nil)
        try cache.update(envName: "work", claude: q)
        #expect(cache.load(envName: "work")?.claude?.fiveHour?.utilization == 1)
        #expect(cache.load(envName: "personal") == nil)
    }
}
