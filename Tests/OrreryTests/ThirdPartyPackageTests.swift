import Testing
import Foundation
@testable import OrreryCore

@Suite("ThirdPartyPackage")
struct ThirdPartyPackageTests {
    @Test("source is codable with git case")
    func gitSourceCodec() throws {
        let src: ThirdPartySource = .git(url: "https://example.com/repo", ref: "main")
        let data = try JSONEncoder().encode(src)
        let decoded = try JSONDecoder().decode(ThirdPartySource.self, from: data)
        #expect(decoded == src)
    }

    @Test("step copyFile codec")
    func copyFileCodec() throws {
        let step: ThirdPartyStep = .copyFile(from: "a.js", to: "b.js")
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(ThirdPartyStep.self, from: data)
        #expect(decoded == step)
    }

    @Test("package aggregates id + steps")
    func packageAggregates() {
        let pkg = ThirdPartyPackage(
            id: "cc-statusline",
            displayName: "cc-statusline",
            description: "demo",
            source: .git(url: "https://example.com", ref: "main"),
            steps: [.copyFile(from: "a", to: "b")]
        )
        #expect(pkg.id == "cc-statusline")
        #expect(pkg.steps.count == 1)
    }
}
