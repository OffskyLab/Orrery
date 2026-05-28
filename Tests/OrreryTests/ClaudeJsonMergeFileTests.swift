import Foundation
import Testing
@testable import OrreryCore

@Suite("ClaudeJsonMerge file paths")
struct ClaudeJsonMergeFilePathTests {
    @Test("identityFileURL lives under accountDir as claude-identity.json")
    func identityFilePath() {
        let acctDir = URL(fileURLWithPath: "/tmp/fake-acct")
        let url = ClaudeJsonMerge.identityFileURL(accountDir: acctDir)
        #expect(url.path == "/tmp/fake-acct/claude-identity.json")
    }

    @Test("sharedFileURL lives under workspaceDir as claude-shared.json")
    func sharedFilePath() {
        let wsDir = URL(fileURLWithPath: "/tmp/fake-ws")
        let url = ClaudeJsonMerge.sharedFileURL(workspaceDir: wsDir)
        #expect(url.path == "/tmp/fake-ws/claude-shared.json")
    }
}

@Suite("ClaudeJsonMerge load/save JSON")
struct ClaudeJsonMergeFileIOTests {
    @Test("saveJSON then loadJSON round-trips a dict")
    func roundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original: [String: Any] = [
            "oauthAccount": ["emailAddress": "a@b.com"],
            "numStartups": 5,
            "nestedList": [1, 2, 3],
        ]
        try ClaudeJsonMerge.saveJSON(original, at: tmp)

        let loaded = ClaudeJsonMerge.loadJSON(at: tmp)
        #expect(loaded != nil)
        #expect(loaded?["numStartups"] as? Int == 5)
        #expect((loaded?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "a@b.com")
        #expect((loaded?["nestedList"] as? [Int])?.count == 3)
    }

    @Test("loadJSON returns nil for missing file (non-throwing)")
    func loadMissingReturnsNil() {
        let absent = URL(fileURLWithPath: "/tmp/cmf-nonexistent-\(UUID().uuidString).json")
        #expect(ClaudeJsonMerge.loadJSON(at: absent) == nil)
    }

    @Test("loadJSON returns nil for malformed file (non-throwing)")
    func loadMalformedReturnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmf-malformed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("this is not json".utf8).write(to: tmp)
        #expect(ClaudeJsonMerge.loadJSON(at: tmp) == nil)
    }

    @Test("saveJSON creates parent directory if missing")
    func saveCreatesParent() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmf-nested-\(UUID().uuidString)")
        let target = parent.appendingPathComponent("sub").appendingPathComponent("file.json")
        defer { try? FileManager.default.removeItem(at: parent) }

        try ClaudeJsonMerge.saveJSON(["k": "v"], at: target)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
