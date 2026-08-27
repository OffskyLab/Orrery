import Foundation
import Testing
@testable import OrreryCore

/// `userHomeURL()` is the seam `ORRERY_USER_HOME` redirects, and
/// `orreryHomeURL()` is the one `ORRERY_HOME` redirects. Reaching past either to
/// `FileManager.default.homeDirectoryForCurrentUser` produces the same bug every
/// time: the value is isolated, the *destination* is not, so an isolated run
/// reads or writes the developer's real home.
///
/// This repo has paid for that four times — a dangled memory symlink, a
/// self-update that ran the installed binary rather than the built one, a
/// `source` block written into a real `~/.zshrc` pointing at a deleted temp dir,
/// and nine repointed account symlinks. Each fix ended with "grep for
/// `homeDirectoryForCurrentUser` before trusting a new call site", which is a
/// note that only works while someone remembers to read it. This is that grep,
/// as a test.
///
/// Adding a legitimate use means adding it to `allowed` **with the reason**. The
/// bar is that the code genuinely wants the real user, not a path the seam should
/// be able to redirect.
@Suite("home isolation seam")
struct HomeSeamTests {

    /// The only file allowed to read the real home outright: it is the seam.
    private let allowedFile = "OrreryHome.swift"

    /// Line-level exemptions, as (file, required substring). Deliberately not a
    /// file-level allowlist — the first draft of this test exempted
    /// `ClaudeKeychain.swift` wholesale for its username fallback, which also
    /// hid two real path violations in the same file. A file that mixes a
    /// legitimate use with an illegitimate one is exactly where the hole would be.
    private let allowedLines: [(file: String, mustContain: String)] = [
        // The macOS Keychain account name is the real username, not a path, and
        // the login Keychain is global — ORRERY_HOME never isolated it. Under an
        // isolated home `lastPathComponent` would be "orrery-test-<uuid>", which
        // is not anyone's account name.
        ("ClaudeKeychain.swift", "lastPathComponent"),
    ]

    @Test("nothing reaches past the home seam to the real home directory")
    func noRawHomeDirectoryUses() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrreryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources")

        let fm = FileManager.default
        var offenders: [String] = []

        let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.lastPathComponent
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("homeDirectoryForCurrentUser")
            else { continue }

            if name == allowedFile { continue }

            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("homeDirectoryForCurrentUser") {
                let exempt = allowedLines.contains {
                    $0.file == name && line.contains($0.mustContain)
                }
                if exempt { continue }
                offenders.append("  \(name):\(i + 1)  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        #expect(offenders.isEmpty, """
            These reach past the home seam. Use `userHomeURL()` for a home-relative \
            path and `orreryHomeURL()` for orrery's own directory, so an isolated \
            run cannot touch the developer's real home. If a use is genuinely about \
            the real *user* rather than a redirectable path, add its file to this \
            suite's `allowed` list with the reason.
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// Guards the guard: a walker that silently found nothing — a wrong path, a
    /// failed enumerator — would report success forever.
    @Test("the source tree was actually scanned")
    func scanReachedTheSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")

        let fm = FileManager.default
        var swiftFiles = 0
        let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { swiftFiles += 1 }
        }
        #expect(swiftFiles > 50, "expected to walk the whole Sources tree, saw \(swiftFiles) files")

        let seam = sources.appendingPathComponent("OrreryCore/Storage/OrreryHome.swift")
        #expect(fm.fileExists(atPath: seam.path),
                "the allowlist names OrreryHome.swift; if it moved, this suite is guarding nothing")

        // The line-level exemption is only worth having while the file it names
        // still exists and still contains the shape it exempts. A stale entry is
        // a hole with a comment explaining why it is fine.
        let keychain = sources.appendingPathComponent("OrreryCore/Setup/ClaudeKeychain.swift")
        let text = try String(contentsOf: keychain, encoding: .utf8)
        #expect(text.contains("homeDirectoryForCurrentUser.lastPathComponent"),
                "ClaudeKeychain no longer has the username fallback this suite exempts; drop the entry")
    }
}
