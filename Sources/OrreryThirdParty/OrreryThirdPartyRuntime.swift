import Foundation
import OrreryCore

/// Entry point the binary calls at startup to wire concrete ThirdParty
/// implementations into `OrreryCore.ThirdPartyRuntime`. Stubbed until the
/// runner lands in a later task.
public enum OrreryThirdPartyRuntime {
    public static func register() {
        // Filled in when ManifestRunner exists.
    }
}
