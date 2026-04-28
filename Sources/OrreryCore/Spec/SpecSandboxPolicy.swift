import Foundation

/// Sandbox policy that gates shell commands extracted from a spec's
/// "## 驗收標準" section. Three layers of defence (see D10):
///
/// - L1: caller drives the dry-run toggle (this type does not).
/// - L2: `decide(command:)` applies blocklist-first, allowlist-second.
/// - L3: caller enforces timeout / stdout cap / CWD.
///
/// This type is intentionally pure: no I/O, no process execution. It only
/// answers "is this string safe to execute under my rules?".
public struct SpecSandboxPolicy {

    /// Prefix tokens. A command is allowed iff trimmed command starts with one
    /// of these AND the character immediately after the prefix is end-of-string
    /// or whitespace (so `grepx` is NOT allowed by prefix `grep`).
    public static let allowlistPrefixes: [String] = [
        "swift build", "swift test", "swift package",
        "grep", "rg", "test",
        "git diff", "git log", "git status",
        "echo", "cat", "ls", "head", "tail",
        ".build/debug/orrery"
    ]

    /// Substring tokens. If ANY token appears anywhere in the trimmed command,
    /// the command is blocked — blocklist is evaluated BEFORE allowlist so
    /// mixed lines like `git diff && git push` are caught.
    public static let blocklistTokens: [String] = [
        "rm", "sudo", "dd", "mkfs",
        "git push", "git reset --hard", "git commit",
        "git checkout", "git clean", "git restore", "git stash",
        "|sh", "| sh", "|bash", "| bash", "bash -c", "sh -c",
        "cd /", "cd ~", "pushd", "popd"
    ]

    public static let perCommandTimeoutDefault: TimeInterval = 60
    public static let overallTimeoutDefault: TimeInterval = 600
    public static let stdoutByteCap: Int = 1_000_000

    public enum Decision: Equatable {
        case allowed
        case blocked(reason: String)
    }

    /// Decide whether to run a single command. Order matters:
    /// 1. Trim — empty command is blocked.
    /// 2. Blocklist substring scan → blocked.
    /// 3. Allowlist word-boundary prefix check → allowed.
    /// 4. Otherwise → blocked (not in allowlist).
    public static func decide(command: String) -> Decision {
        let t = command.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            return .blocked(reason: "empty command")
        }

        // Blocklist first.
        for token in blocklistTokens where t.contains(token) {
            return .blocked(reason: "blocklist:\(token)")
        }

        // Allowlist with word-boundary suffix check.
        for prefix in allowlistPrefixes where t.hasPrefix(prefix) {
            let afterIndex = t.index(t.startIndex, offsetBy: prefix.count)
            if afterIndex == t.endIndex {
                return .allowed
            }
            let nextChar = t[afterIndex]
            if nextChar.isWhitespace {
                return .allowed
            }
            // prefix matched but boundary failed (e.g. `grepx`); keep scanning
            // in case a longer allowlist entry matches. Most prefixes are
            // unique, but `test` vs `testfoo` benefits from this.
        }

        return .blocked(reason: "not in allowlist")
    }

    /// Regex-based approximation of a Python AST lint. This is NOT a true AST
    /// parse — MVP deny-list only. Q8 (open question) tracks upgrading to a
    /// real `python3 -c 'import ast; …'` check.
    ///
    /// Rules (deny any match):
    /// - `__import__`
    /// - `\bexec\s*\(`
    /// - `\beval\s*\(`
    /// - `open\s*\([^)]*['"](?:w|a)`
    /// - `import\s+(?!ast|json|sys|re)\w+`
    public static func lintPythonRegex(snippet: String) -> Decision {
        for (rule, pattern) in pythonDenyRules {
            if matches(pattern: pattern, in: snippet) {
                return .blocked(reason: "python regex lint failed: \(rule)")
            }
        }
        return .allowed
    }

    // MARK: - Private

    private static let pythonDenyRules: [(String, String)] = [
        ("dunder-import",     #"__import__"#),
        ("exec-call",         #"\bexec\s*\("#),
        ("eval-call",         #"\beval\s*\("#),
        ("open-write",        #"open\s*\([^)]*['""](?:w|a)"#),
        ("disallowed-import", #"import\s+(?!ast|json|sys|re)\w+"#)
    ]

    private static func matches(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
