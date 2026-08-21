import Foundation
import AIToolKit

/// Registers the tools this build ships with.
///
/// Must run before anything that iterates tools — above all before
/// `AccountMigration`'s four one-shot migrations, which record the tools they
/// covered and would otherwise lock out a tool that registered afterwards.
/// `main.swift` sequences this explicitly rather than relying on load order.
public enum AIToolRegistration {

    /// Registers into the shared registry. Idempotent.
    public static func registerBuiltInTools() {
        registerBuiltInTools(into: .shared)
    }

    /// Registry taken as a parameter so tests never touch the shared instance.
    public static func registerBuiltInTools(into registry: AIToolRegistry) {
        for tool in Tool.allCases {
            registry.register(tool.aiTool)
        }
    }
}
