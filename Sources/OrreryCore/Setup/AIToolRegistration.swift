import Foundation
import AIToolKit

/// Registers the tools this build ships with.
///
/// No production code reads the registry yet: `AccountMigration`'s five
/// one-shot migrations still derive their tool set from `Tool`, which is total
/// at compile time and so cannot be affected by when this runs. The
/// enum remains the source of truth for this phase; this populates the registry
/// alongside it.
///
/// The ordering nonetheless matters once those call sites move. A registry is
/// total only if registration ran, so a migration that executes before this
/// would see a short tool list, skip whatever was missing, and write its flag
/// anyway — leaving that tool unmigrated on the machine, invisibly and
/// permanently. `main.swift` therefore sequences this above them explicitly
/// now, rather than relying on load order or on someone noticing later.
public enum AIToolRegistration {

    /// Registers into the shared registry. Idempotent.
    ///
    /// Throws whatever the registry refuses. Built-in ids come from
    /// `Tool.rawValue` and are known-valid, so a throw here means a built-in
    /// id has become something a host cannot write down — a bug that must
    /// surface, not be swallowed at the call site.
    public static func registerBuiltInTools() throws {
        try registerBuiltInTools(into: .shared)
    }

    /// Registry taken as a parameter so tests never touch the shared instance.
    public static func registerBuiltInTools(into registry: AIToolRegistry) throws {
        for tool in Tool.allCases {
            try registry.register(tool.aiTool)
        }
    }
}
