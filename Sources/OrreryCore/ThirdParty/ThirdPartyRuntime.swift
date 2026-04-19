import Foundation

/// Factories registered by the binary at startup so Core-resident CLI commands
/// can obtain concrete implementations that live in `OrreryThirdParty` without
/// Core depending on that target.
public enum ThirdPartyRuntime {
    nonisolated(unsafe) public static var makeRunner: (@Sendable () -> ThirdPartyRunner)?
    nonisolated(unsafe) public static var makeRegistry: (@Sendable () -> ThirdPartyRegistry)?

    public static func runner() throws -> ThirdPartyRunner {
        guard let make = makeRunner else {
            throw ThirdPartyError.stepFailed(reason: "ThirdPartyRuntime.makeRunner not registered")
        }
        return make()
    }

    public static func registry() throws -> ThirdPartyRegistry {
        guard let make = makeRegistry else {
            throw ThirdPartyError.stepFailed(reason: "ThirdPartyRuntime.makeRegistry not registered")
        }
        return make()
    }
}
