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
            Localizer.string("toolSetup.success"),
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
            "delete.confirmSingle",
            "list.empty",
            "resume.pickPrompt",
            "delegate.success",
            "run.success",
            "memory.statusTitle",
            "toolSetup.success",
        ]
        XCTAssertTrue(keys.allSatisfy { !(L10nData.en[$0] ?? "").isEmpty })
        XCTAssertTrue(keys.allSatisfy { !(L10nData.zhHant[$0] ?? "").isEmpty })
    }

    func testLocalesHaveIdenticalKeySets() {
        // Validator enforces this at build time already, but a runtime guard
        // catches any accidental drift if the check is ever bypassed.
        XCTAssertEqual(Set(L10nData.en.keys), Set(L10nData.zhHant.keys))
    }
}
