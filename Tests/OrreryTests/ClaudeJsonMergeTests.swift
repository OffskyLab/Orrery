import Foundation
import Testing
@testable import OrreryCore

@Suite("ClaudeJsonMerge categories")
struct ClaudeJsonMergeCategoryTests {
    @Test("identity fields are per-account")
    func identityIsPerAccount() {
        for k in ["oauthAccount", "userID", "anonymousId"] {
            #expect(ClaudeJsonMerge.fieldCategory(k) == .perAccount, "\(k) should be perAccount")
        }
    }

    @Test("projects is the canonical shared field")
    func projectsIsShared() {
        #expect(ClaudeJsonMerge.fieldCategory("projects") == .shared)
    }

    @Test("low-risk shared fields are categorized shared")
    func lowRiskSharedFields() {
        for k in ["tipsHistory", "githubRepoPaths", "seenNotifications",
                  "claudeAiMcpEverConnected", "hasSeenTasksHint",
                  "effortCalloutDismissed", "lastReleaseNotesSeen",
                  "deepLinkTerminal"] {
            #expect(ClaudeJsonMerge.fieldCategory(k) == .shared, "\(k) should be shared")
        }
    }

    @Test("unknown fields default to per-account (conservative)")
    func unknownDefaultsToPerAccount() {
        #expect(ClaudeJsonMerge.fieldCategory("someBrandNewFieldClaudeMightAddLater")
            == .perAccount)
    }

    @Test("per-account setup state and counters are categorized correctly")
    func setupAndCountersAreSampled() {
        for k in ["firstStartTime", "claudeCodeFirstTokenDate",
                  "hasCompletedOnboarding", "lastOnboardingVersion",
                  "migrationVersion", "numStartups",
                  "cachedGrowthBookFeatures", "cachedStatsigGates"] {
            #expect(ClaudeJsonMerge.fieldCategory(k) == .perAccount, "\(k) should be perAccount")
        }
    }
}

@Suite("ClaudeJsonMerge.split")
struct ClaudeJsonMergeSplitTests {
    @Test("splits known per-account and shared fields into the right buckets")
    func splitsKnownFields() throws {
        let merged: [String: Any] = [
            "oauthAccount": ["emailAddress": "a@b.com"],
            "userID": "uid-1",
            "projects": ["/path/A": ["allowedTools": []]],
            "tipsHistory": ["someTip": 1],
            "numStartups": 42,
        ]
        let url = try writeTempJSON(merged)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ClaudeJsonMerge.split(claudeJSONURL: url)

        #expect((result.identity["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "a@b.com")
        #expect(result.identity["userID"] as? String == "uid-1")
        #expect(result.identity["numStartups"] as? Int == 42)
        #expect(result.identity["projects"] == nil)
        #expect(result.identity["tipsHistory"] == nil)

        #expect((result.shared["projects"] as? [String: Any])?.keys.contains("/path/A") == true)
        #expect((result.shared["tipsHistory"] as? [String: Any])?["someTip"] as? Int == 1)
        #expect(result.shared["oauthAccount"] == nil)
        #expect(result.shared["numStartups"] == nil)
    }

    @Test("unknown fields go to identity (per-account default)")
    func unknownFieldsGoToIdentity() throws {
        let merged: [String: Any] = [
            "futureUnknownField": "value",
            "projects": [:],
        ]
        let url = try writeTempJSON(merged)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ClaudeJsonMerge.split(claudeJSONURL: url)
        #expect(result.identity["futureUnknownField"] as? String == "value")
        #expect(result.shared["futureUnknownField"] == nil)
    }

    @Test("missing file throws — caller decides how to recover")
    func missingFileThrows() {
        let absent = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        #expect(throws: ClaudeJsonMerge.Error.self) {
            try ClaudeJsonMerge.split(claudeJSONURL: absent)
        }
    }
}

// Helper used by split + merge tests.
private func writeTempJSON(_ obj: [String: Any]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudemerge-\(UUID().uuidString).json")
    let data = try JSONSerialization.data(withJSONObject: obj,
                                           options: [.sortedKeys])
    try data.write(to: url)
    return url
}
