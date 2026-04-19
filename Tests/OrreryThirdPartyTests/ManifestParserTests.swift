import Testing
import Foundation
@testable import OrreryThirdParty
@testable import OrreryCore

@Suite("ManifestParser")
struct ManifestParserTests {
    private let ccStatuslineJSON = """
    {
      "id": "cc-statusline",
      "displayName": "cc-statusline",
      "description": "demo",
      "source": { "type": "git", "url": "https://example.com/x", "ref": "main" },
      "steps": [
        { "type": "copyFile", "from": "a.js", "to": "b.js" },
        { "type": "copyGlob", "from": "hooks/*.js", "toDir": "hooks" },
        { "type": "patchSettings", "file": "settings.json", "patch": { "statusLine": {} } }
      ]
    }
    """

    @Test("parses valid manifest into ThirdPartyPackage")
    func parsesValid() throws {
        let pkg = try ManifestParser.parse(Data(ccStatuslineJSON.utf8))
        #expect(pkg.id == "cc-statusline")
        #expect(pkg.steps.count == 3)
        if case .git(_, let ref) = pkg.source { #expect(ref == "main") } else { Issue.record("expected git") }
    }

    @Test("missing source.url throws")
    func missingURLThrows() throws {
        let bad = """
        { "id": "x", "displayName": "x", "description": "",
          "source": { "type": "git", "ref": "main" },
          "steps": [] }
        """
        #expect(throws: (any Error).self) {
            _ = try ManifestParser.parse(Data(bad.utf8))
        }
    }

    @Test("unknown step type throws")
    func unknownStepThrows() throws {
        let bad = """
        { "id": "x", "displayName": "x", "description": "",
          "source": { "type": "git", "url": "u", "ref": "main" },
          "steps": [ { "type": "unknownStep" } ] }
        """
        #expect(throws: (any Error).self) {
            _ = try ManifestParser.parse(Data(bad.utf8))
        }
    }
}
