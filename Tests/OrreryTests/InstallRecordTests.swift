import Testing
import Foundation
@testable import OrreryCore

@Suite("InstallRecord")
struct InstallRecordTests {
    @Test("round-trips with all BeforeState cases")
    func roundTrip() throws {
        let record = InstallRecord(
            packageID: "cc-statusline",
            resolvedRef: String(repeating: "a", count: 40),
            manifestRef: "main",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            copiedFiles: ["statusline.js", "hooks/file-tracker.js"],
            patchedSettings: [
                .init(file: "settings.json", entries: [
                    .init(keyPath: ["statusLine"], before: .absent),
                    .init(keyPath: ["hooks", "UserPromptSubmit"],
                          before: .array(appendedElements: [.object(["matcher": .string(".*")])])),
                    .init(keyPath: ["model"],
                          before: .scalar(previous: .string("old"))),
                    .init(keyPath: ["env"],
                          before: .object(addedKeys: ["NEW_KEY"])),
                ])
            ]
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(InstallRecord.self, from: data)
        #expect(decoded == record)
    }
}
