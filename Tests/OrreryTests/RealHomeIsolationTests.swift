import Testing
import Foundation
@testable import OrreryCore

/// A canary, not a barrier.
///
/// On 2026-08-25 three claude accounts in the real pool were found with
/// `projects`, `sessions` and `session-env` repointed at
/// `/var/folders/.../orrery-rc-probe-<uuid>/orrery-home/shared/claude/...` —
/// sandbox directories that no longer existed, so every session write against
/// them failed with ENOENT. A test had sourced the generated `activate.sh`
/// including its trailing `_orrery_init`, which shells out to the *installed*
/// orrery-bin; that process ran with the probe's `ORRERY_HOME` but reached the
/// developer's real account pool, and the sandbox was deleted on the way out.
/// `a0acdd2` stopped the sourcing and `generatedShellScriptWithoutInit()` keeps
/// it stopped.
///
/// This suite does not *prevent* a future escape — nothing in swift-testing can
/// order it after every other suite. It does something nearly as useful: the
/// damage an escape leaves behind is persistent, so the next `swift test` on the
/// machine goes red and names the offending link. The incident above sat
/// unnoticed for three days across several full-suite runs; this shrinks that
/// window to a single run.
///
/// Deliberately reads `homeDirectoryForCurrentUser` rather than the project's
/// `userHomeURL()` seam: the real home is exactly what is under test, so the
/// isolation seam other tests set must not apply here. `LinkMemoryCommandTests`
/// reads the real home for the same reason.
///
/// A machine with no account pool — CI, a fresh checkout — has nothing to check
/// and the test returns.
@Suite("RealHomeIsolation")
struct RealHomeIsolationTests {

    @Test("no symlink in the real account pool points outside the real ORRERY_HOME")
    func accountSymlinksStayInsideOrreryHome() throws {
        let fm = FileManager.default
        let realHome = fm.homeDirectoryForCurrentUser.appendingPathComponent(".orrery")
        let accounts = realHome.appendingPathComponent("accounts")
        guard fm.fileExists(atPath: accounts.path) else { return }

        var offenders: [String] = []

        for tool in (try? fm.contentsOfDirectory(atPath: accounts.path)) ?? [] {
            let toolDir = accounts.appendingPathComponent(tool)
            for account in (try? fm.contentsOfDirectory(atPath: toolDir.path)) ?? [] {
                let acctDir = toolDir.appendingPathComponent(account)
                for entry in (try? fm.contentsOfDirectory(atPath: acctDir.path)) ?? [] {
                    let link = acctDir.appendingPathComponent(entry)
                    // Only symlinks answer this call, which is what separates
                    // them from the real directories sitting alongside.
                    guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path)
                    else { continue }

                    // A relative destination resolves against the link's own
                    // directory. `gemini-home/<id>/.gemini -> ../../gemini/<id>`
                    // is legitimate and must not be read as an escape.
                    let resolved = dest.hasPrefix("/")
                        ? URL(fileURLWithPath: dest).standardizedFileURL
                        : acctDir.appendingPathComponent(dest).standardizedFileURL

                    if !resolved.path.hasPrefix(realHome.path + "/") {
                        offenders.append("  \(tool)/\(account)/\(entry) -> \(dest)")
                    }
                }
            }
        }

        #expect(offenders.isEmpty, """
            Account symlinks point outside \(realHome.path). Something ran with a \
            sandbox ORRERY_HOME while still reaching the real account pool — see \
            this suite's note for the incident this guards. Offenders:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
