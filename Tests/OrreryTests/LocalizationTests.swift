import XCTest
@testable import OrreryCore

final class LocalizationTests: XCTestCase {
    func testEnglishStringsAreAvailable() {
        let values = [
            Localizer.string("orrery.abstract"),
            Localizer.string("create.abstract"),
            Localizer.string("create.nameHelp"),
            Localizer.string("list.abstract"),
            Localizer.string("delete.abstract"),
            Localizer.string("resume.abstract"),
            Localizer.string("delegate.abstract"),
            Localizer.string("run.abstract"),
            Localizer.string("memory.abstract"),
            Localizer.string("toolSetup.installed"),
        ]
        XCTAssertEqual(values.count, 10)
        XCTAssertTrue(values.allSatisfy { !$0.isEmpty })
    }

    func testParameterizedLookupSubstitutes() {
        let value = L10n.Create.created("foo")
        XCTAssertTrue(value.contains("foo"))
    }

    func testBothLocalesContainKnownKeys() {
        // Strings are compiled directly into the binary via codegen; the
        // generated `L10nData` holds the per-locale dictionaries.
        let keys = [
            "orrery.abstract",
            "create.abstract",
            "create.alreadyExists",
            "delete.abstract",
            "list.empty",
            "resume.abstract",
            "delegate.abstract",
            "run.abstract",
            "memory.abstract",
            "toolSetup.installed",
        ]
        XCTAssertTrue(keys.allSatisfy { !(L10nData.en[$0] ?? "").isEmpty })
        XCTAssertTrue(keys.allSatisfy { !(L10nData.zhHant[$0] ?? "").isEmpty })
    }

    func testLocalesHaveIdenticalKeySets() {
        // Validator enforces this at build time already, but a runtime guard
        // catches any accidental drift if the check is ever bypassed. Add new
        // locales here as they're introduced.
        let baseKeys = Set(L10nData.en.keys)
        XCTAssertEqual(baseKeys, Set(L10nData.zhHant.keys))
        XCTAssertEqual(baseKeys, Set(L10nData.ja.keys))
    }
}
