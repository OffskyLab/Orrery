import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("ManifestRunner — uninstall")
struct ManifestRunnerUninstallTests {
    private struct Fixture {
        let store: EnvironmentStore
        let envName: String
        let sourceDir: URL
        let runner: ManifestRunner
        let pkg: ThirdPartyPackage
    }

    private func makeFixture() throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-runner-uninst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = EnvironmentStore(homeURL: home)
        try store.save(OrreryEnvironment(name: "dev"))
        try FileManager.default.createDirectory(
            at: store.toolConfigDir(tool: .claude, environment: "dev"),
            withIntermediateDirectories: true)

        let src = home.appendingPathComponent("src")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("hooks"),
            withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src.appendingPathComponent("statusline.js"))
        try Data("y".utf8).write(to: src.appendingPathComponent("hooks/a.js"))

        let pkg = ThirdPartyPackage(
            id: "cc-statusline",
            displayName: "cc-statusline",
            description: "",
            source: .vendored(bundlePath: src.path),
            steps: [
                .copyFile(from: "statusline.js", to: "statusline.js"),
                .copyGlob(from: "hooks/*.js", toDir: "hooks"),
                .patchSettings(file: "settings.json", patch: .object([
                    "statusLine": .object(["type": .string("command")])
                ])),
            ])
        return Fixture(store: store, envName: "dev",
                       sourceDir: src, runner: ManifestRunner(store: store, fetcher: VendoredSource()),
                       pkg: pkg)
    }

    @Test("uninstall removes copied files, reverses settings, deletes lock")
    func uninstallRoundTrips() throws {
        let f = try makeFixture()
        _ = try f.runner.install(f.pkg, into: f.envName,
                                 refOverride: nil, forceRefresh: false)
        try f.runner.uninstall(packageID: "cc-statusline", from: f.envName)

        let claudeDir = f.store.toolConfigDir(tool: .claude, environment: f.envName)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: claudeDir.appendingPathComponent("statusline.js").path) == false)
        #expect(fm.fileExists(atPath: claudeDir.appendingPathComponent("hooks/a.js").path) == false)
        #expect(fm.fileExists(atPath: claudeDir.appendingPathComponent(".thirdparty/cc-statusline.lock.json").path) == false)
        #expect(fm.fileExists(atPath: claudeDir.appendingPathComponent("settings.json").path) == false)
    }

    @Test("uninstall when not installed throws notInstalled")
    func uninstallNotInstalled() throws {
        let f = try makeFixture()
        #expect(throws: ThirdPartyError.self) {
            try f.runner.uninstall(packageID: "cc-statusline", from: f.envName)
        }
    }

    @Test("listInstalled returns one record after install")
    func listAfterInstall() throws {
        let f = try makeFixture()
        _ = try f.runner.install(f.pkg, into: f.envName,
                                 refOverride: nil, forceRefresh: false)
        let records = try f.runner.listInstalled(in: f.envName)
        #expect(records.count == 1)
        #expect(records[0].packageID == "cc-statusline")
    }
}
