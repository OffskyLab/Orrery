import Foundation

/// Single-quoting for values crossing the Swift → shell boundary.
///
/// Everything orrery hands back for the shell to `eval` or `.` goes through
/// here. Inside single quotes the shell treats every character literally, so
/// the only thing needing escaping is a single quote itself: close the quote,
/// emit an escaped quote, reopen.
public enum ShellQuote {
    public static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
