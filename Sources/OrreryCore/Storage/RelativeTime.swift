import Foundation

/// Compact relative-time formatter for `orrery list`. Output is human-friendly
/// English (e.g. "5m ago", "2d ago") to keep alignment predictable across rows.
public enum RelativeTime {
    public static func ago(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60          { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60          { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24            { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30             { return "\(days)d ago" }
        let months = days / 30
        if months < 12           { return "\(months)mo ago" }
        return "\(months / 12)y ago"
    }
}
