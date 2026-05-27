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

@Suite("ClaudeJsonMerge.merge")
struct ClaudeJsonMergeMergeTests {
    @Test("union of identity and shared dicts")
    func unionOfBoth() throws {
        let identity: [String: Any] = [
            "oauthAccount": ["emailAddress": "a@b.com"],
            "numStartups": 5,
        ]
        let shared: [String: Any] = [
            "projects": ["/A": ["allowedTools": []]],
            "tipsHistory": [:],
        ]
        let result = ClaudeJsonMerge.merge(identity: identity, shared: shared)

        #expect((result["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "a@b.com")
        #expect(result["numStartups"] as? Int == 5)
        #expect((result["projects"] as? [String: Any])?.keys.contains("/A") == true)
        #expect(result["tipsHistory"] is [String: Any])
        #expect(result.count == 4)
    }

    @Test("on conflicting key, identity wins (defensive)")
    func identityWinsOnConflict() {
        let identity: [String: Any] = ["someKey": "identity-value"]
        let shared: [String: Any]   = ["someKey": "shared-value"]
        let result = ClaudeJsonMerge.merge(identity: identity, shared: shared)
        #expect(result["someKey"] as? String == "identity-value")
    }

    @Test("split then merge is identity for a well-categorized input")
    func splitMergeRoundTrip() throws {
        let original: [String: Any] = [
            "oauthAccount": ["emailAddress": "x@y.com"],
            "projects": ["/path": ["k": "v"]],
            "numStartups": 7,
            "tipsHistory": ["tip1": 1],
        ]
        let url = try writeTempJSON(original)
        defer { try? FileManager.default.removeItem(at: url) }

        let split = try ClaudeJsonMerge.split(claudeJSONURL: url)
        let merged = ClaudeJsonMerge.merge(identity: split.identity, shared: split.shared)

        #expect(merged.count == 4)
        #expect(merged["numStartups"] as? Int == 7)
        #expect((merged["projects"] as? [String: Any])?["/path"] != nil)
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
