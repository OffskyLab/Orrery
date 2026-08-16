import Testing
import Foundation
@testable import OrreryCore

@Suite("ClaudeSessionHook")
struct ClaudeSessionHookTests {
    var tmpDir: URL!
    var registry: PhantomRegistry!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-session-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        registry = PhantomRegistry(homeURL: tmpDir)
        try registry.write(PhantomEntry(
            supervisorPid: 4242, supervisorStartedAt: 1.0, tool: "claude",
            tty: nil, cwd: "/tmp/p", workspace: "origin", account: "work",
            sessionId: nil, sessionIdSource: .probe, updatedAt: 1.0), id: "4242")
    }

    private func payload(_ json: String) -> Data { Data(json.utf8) }

    @Test("SessionStart records the session id as authoritative")
    func recordsSessionId() throws {
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"real-1","source":"startup"}"#),
            phantomId: "4242", registry: registry)

        let entry = try #require(registry.read(id: "4242"))
        #expect(entry.sessionId == "real-1")
        #expect(entry.sessionIdSource == .hook)
    }

    @Test("a later SessionStart overwrites an earlier session id")
    func overwritesOnResume() throws {
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"first","source":"startup"}"#),
            phantomId: "4242", registry: registry)
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"second","source":"clear"}"#),
            phantomId: "4242", registry: registry)

        #expect(try #require(registry.read(id: "4242")).sessionId == "second")
    }

    @Test("no phantom id means no write — an unsupervised claude is a no-op")
    func noPhantomId() throws {
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"x"}"#),
            phantomId: nil, registry: registry)

        #expect(try #require(registry.read(id: "4242")).sessionId == nil)
    }

    @Test("an unknown phantom id is ignored rather than creating an entry")
    func unknownPhantomId() {
        ClaudeSessionHook.apply(
            payload: payload(#"{"hook_event_name":"SessionStart","session_id":"x"}"#),
            phantomId: "9999", registry: registry)

        #expect(registry.read(id: "9999") == nil)
    }

    @Test("malformed JSON is ignored without crashing")
    func malformedPayload() throws {
        ClaudeSessionHook.apply(payload: payload("not json"),
                                phantomId: "4242", registry: registry)
        #expect(try #require(registry.read(id: "4242")).sessionId == nil)
    }

    @Test("installer adds SessionStart and SessionEnd hooks")
    func installerWrites() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        ClaudeSessionHookInstaller.install(command: "/bin/hook --session-event",
                                          settingsURL: settings)
        let text = try String(contentsOf: settings, encoding: .utf8)
        #expect(text.contains("SessionStart"))
        #expect(text.contains("SessionEnd"))
        #expect(text.contains("/bin/hook --session-event"))
    }

    @Test("installing twice does not duplicate the hook entries")
    func installerIdempotent() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        ClaudeSessionHookInstaller.install(command: "/bin/hook --session-event",
                                          settingsURL: settings)
        ClaudeSessionHookInstaller.install(command: "/bin/hook --session-event",
                                          settingsURL: settings)
        let text = try String(contentsOf: settings, encoding: .utf8)
        let occurrences = text.components(separatedBy: "/bin/hook --session-event").count - 1
        #expect(occurrences == 2)  // one under SessionStart, one under SessionEnd
    }

    @Test("installing preserves unrelated settings and other hooks")
    func installerAdditive() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        try #"{"model":"opus","hooks":{"Notification":[{"matcher":"auth_success","hooks":[{"type":"command","command":"/bin/other"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)

        ClaudeSessionHookInstaller.install(command: "/bin/hook --session-event",
                                          settingsURL: settings)

        let text = try String(contentsOf: settings, encoding: .utf8)
        #expect(text.contains("\"opus\""))
        #expect(text.contains("/bin/other"))
        #expect(text.contains("/bin/hook --session-event"))
    }
}
