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
