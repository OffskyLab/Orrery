import Testing
@testable import OrreryCore

@Suite("ShellQuote")
struct ShellQuoteTests {
    @Test("plain text is wrapped in single quotes")
    func plain() {
        #expect(ShellQuote.single("work") == "'work'")
    }

    @Test("embedded single quote is escaped so the shell sees one literal quote")
    func embeddedQuote() {
        #expect(ShellQuote.single("it's") == #"'it'\''s'"#)
    }

    @Test("shell metacharacters are inert inside single quotes")
    func metacharacters() {
        #expect(ShellQuote.single("a b; rm -rf /") == "'a b; rm -rf /'")
        #expect(ShellQuote.single("$(whoami)") == "'$(whoami)'")
    }

    @Test("empty string quotes to an empty pair")
    func empty() {
        #expect(ShellQuote.single("") == "''")
    }
}
