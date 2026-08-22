import Foundation
import Testing
import AIToolKit
@testable import OrreryCore

/// The plugin must describe claude exactly as the enum did. This is the test
/// that makes the migration safe: if the two ever disagree, this goes red
/// before a user sees a wrong config directory.
@Suite("ClaudePluginParity")
struct ClaudePluginParityTests {

    /// Anchors `Bundle(for:)` to this test bundle's location. `Bundle.main`
    /// resolves to the `swiftpm-testing-helper` launcher's own path, not the
    /// build-products directory `orrery-claude` is actually built into —
    /// `Bundle(for:)` on a type declared in this module lands beside it
    /// instead, because SwiftPM puts the test bundle in the same directory
    /// as every other build product.
    private final class BundleMarker {}

    private var pluginURL: URL {
        Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("orrery-claude")
    }

    @Test("the plugin describes claude exactly as the built-in bridge does")
    func pluginMatchesBridge() async throws {
        let transport = StdioTransport(
            executable: pluginURL, arguments: [], environment: [:])
        do {
            let remote = try await RemoteAITool.connect(
                transport: transport, timeout: .seconds(5))
            let local = Tool.claude.aiTool

            #expect(remote.id == local.id)
            #expect(remote.displayName == local.displayName)
            #expect(remote.configDirectoryName == local.configDirectoryName)
            #expect(remote.configDirEnvVar == local.configDirEnvVar)
            #expect(remote.authLoginCommand == local.authLoginCommand)
            #expect(remote.installCommand == local.installCommand)
            #expect(remote.sessionSubdirectories == local.sessionSubdirectories)
            #expect(remote.ansiColor == local.ansiColor)

            await transport.terminate()
        } catch {
            await transport.terminate()
            throw error
        }
    }
}
