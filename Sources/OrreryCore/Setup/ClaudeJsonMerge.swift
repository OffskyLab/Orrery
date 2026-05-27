import Foundation

/// v3.1: split / merge `.claude.json` between a per-account identity store
/// and a per-workspace shared store.
///
/// `.claude.json` mixes account-bound identity (oauthAccount, userID, onboarding
/// flags, per-account counters and caches) with workspace-bound shared state
/// (projects[], accumulated tips, recently-seen notifications). Plan 2's
/// launch hook merges the two sources into a single `.claude.json` for claude
/// to read; the exit hook splits the (possibly modified) file back into the
/// two stores.
///
/// Field categorization is curated from the v3.1 spec experiment. Unknown
/// fields default to per-account to avoid accidentally sharing new identity-
/// like data across accounts when claude adds them.
public enum ClaudeJsonMerge {

    /// Where a top-level `.claude.json` key belongs.
    public enum FieldCategory {
        /// Belongs to a single Account — identity, per-account setup state,
        /// counters, caches that claude will regenerate per account.
        case perAccount
        /// Belongs to the Workspace — shared across all Accounts pinned to it.
        case shared
    }

    /// Top-level keys that are explicitly per-account.
    /// Source: v3.1 spec design doc + the 2026-05-27 capture experiment.
    private static let perAccountKeys: Set<String> = [
        // Identity (hard-bound to the OAuth account)
        "oauthAccount", "userID", "anonymousId",
        // Per-account one-time setup state
        "firstStartTime", "claudeCodeFirstTokenDate",
        "hasCompletedOnboarding", "lastOnboardingVersion",
        "migrationVersion",
        "opusProMigrationComplete", "sonnet1m45MigrationComplete",
        "sonnet45MigrationComplete",
        "appleTerminalSetupInProgress", "appleTerminalBackupPath",
        "officialMarketplaceAutoInstallAttempted",
        "officialMarketplaceAutoInstalled",
        "optionAsMetaKeyInstalled",
        // Counters
        "numStartups", "opus47LaunchSeenCount", "opus46FeedSeenCount",
        "subscriptionNoticeCount", "promptQueueUseCount", "btwUseCount",
        // Per-account caches (claude will refetch)
        "cachedGrowthBookFeatures", "cachedStatsigGates",
        "cachedDynamicConfigs", "cachedExperimentFeatures",
        "cachedExtraUsageDisabledReason", "cachedChromeExtensionInstalled",
        "additionalModelCostsCache", "additionalModelOptionsCache",
        "clientDataCache", "metricsStatusCache",
        // Per-account fetch timestamps
        "changelogLastFetched", "closedIssuesLastChecked",
        "routineFiredWatermark",
        // Per-account org/plan caches
        "penguinModeOrgEnabled",
        "s1mAccessCache", "s1mNonSubscriberAccessCache",
        "groveConfigCache", "overageCreditGrantCache",
        "passesEligibilityCache",
        "feedbackSurveyState",
        "hasShownOpus46Notice", "hasOpusPlanDefault",
        // Per-account usage stats
        "toolUsage", "skillUsage", "lastPlanModeUse",
        "customApiKeyResponses",
        // Per-account general flags
        "installMethod", "autoUpdates", "autoUpdatesProtectedForNative",
        "hasUsedBackslashReturn", "showSpinnerTree",
        "hasAcknowledgedCostThreshold", "hasVisitedExtraUsage",
        "remoteDialogSeen",
    ]

    /// Top-level keys that are explicitly shared across accounts of a workspace.
    private static let sharedKeys: Set<String> = [
        // The big one — per-project settings, allowedTools, mcpServers, history
        "projects",
        // Accumulated UI hints / dismissals — sharing aggregates the experience
        "tipsHistory",
        "hasSeenTasksHint",
        "effortCalloutDismissed", "effortCalloutV2Dismissed",
        "lastReleaseNotesSeen",
        // User-level preferences that make sense workspace-wide
        "deepLinkTerminal",
        // Recently touched repos / notifications
        "githubRepoPaths",
        "seenNotifications",
        "claudeAiMcpEverConnected",
    ]

    /// Where a top-level key belongs. Unknown keys → per-account (safer default).
    public static func fieldCategory(_ key: String) -> FieldCategory {
        if sharedKeys.contains(key) { return .shared }
        if perAccountKeys.contains(key) { return .perAccount }
        // Default: per-account. Avoids accidentally sharing a new
        // identity-like field claude adds in a future version.
        return .perAccount
    }
}
