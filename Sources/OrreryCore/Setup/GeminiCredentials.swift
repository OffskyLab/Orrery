import Foundation

/// Extracts the plaintext Gemini API key that gemini-cli stored during `/auth`
/// onboarding. Needed because gemini-cli's non-interactive validator
/// (`gemini -p …`) only consults `process.env.GEMINI_API_KEY` — it won't fall
/// through to its own Keychain / encrypted-file lookup — so `orrery delegate
/// --gemini` has to pre-extract the key and inject it.
///
/// Gemini stores the key via a hybrid scheme:
///   1. macOS Keychain (service `gemini-cli-api-key`, account `default-api-key`)
///   2. Fallback file: `<configDir>/gemini-credentials.json`
///      - AES-256-GCM, format `iv(hex):authTag(hex):ciphertext(hex)`
///      - key = `scrypt("gemini-cli-oauth", "<hostname>-<user>-gemini-cli", 32)`
///      - decrypted blob is nested JSON:
///        `{ "gemini-cli-api-key": { "default-api-key": "<stringified JSON>" } }`
///        where the inner string parses to `{ token: { accessToken, … }, … }`
public enum GeminiCredentials {
    /// Returns the API key if one can be retrieved; nil otherwise.
    public static func loadAPIKey(configDir: URL) -> String? {
        if let keychain = readFromKeychain() { return keychain }
        return decryptFile(at: configDir.appendingPathComponent("gemini-credentials.json"))
    }

    // MARK: - Keychain (macOS)

    private static func readFromKeychain() -> String? {
        #if os(macOS)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = [
            "find-generic-password",
            "-s", "gemini-cli-api-key",
            "-a", "default-api-key",
            "-w",
        ]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let jsonData = raw.data(using: .utf8)
        else { return nil }
        return extractAccessToken(from: jsonData)
        #else
        return nil
        #endif
    }

    // MARK: - Encrypted file fallback

    /// Decrypts via a short Node script — gemini-cli already requires Node to
    /// be installed, so using it here adds no new dependency, and Node's
    /// `crypto` has scrypt + AES-GCM built in.
    private static func decryptFile(at url: URL) -> String? {
        guard let ciphertext = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !ciphertext.isEmpty
        else { return nil }

        let script = """
        const crypto = require('crypto');
        const os = require('os');
        const parts = \(jsStringLiteral(ciphertext)).split(':');
        if (parts.length !== 3) process.exit(1);
        const [ivHex, tagHex, ctHex] = parts;
        const salt = `${os.hostname()}-${os.userInfo().username}-gemini-cli`;
        const key = crypto.scryptSync('gemini-cli-oauth', salt, 32);
        const d = crypto.createDecipheriv(
            'aes-256-gcm',
            key,
            Buffer.from(ivHex, 'hex')
        );
        d.setAuthTag(Buffer.from(tagHex, 'hex'));
        process.stdout.write(Buffer.concat([
            d.update(Buffer.from(ctHex, 'hex')),
            d.final()
        ]).toString('utf8'));
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["node", "-e", script]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return extractAccessToken(from: data)
    }

    // MARK: - JSON helpers

    /// Walks the gemini-cli credential structure and returns the API key.
    /// Accepts both shapes seen in practice:
    ///   - Nested file payload: `{ service: { account: "<stringified JSON>" } }`
    ///   - Flat entry (Keychain): `{ token: { accessToken, … }, … }` (already the inner object, sometimes as a JSON string)
    private static func extractAccessToken(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // Flat form: already an entry with `token.accessToken`.
        if let entry = obj as? [String: Any],
           let accessToken = accessToken(in: entry) {
            return accessToken
        }

        // Nested form from the encrypted file: dig into service → account.
        if let root = obj as? [String: Any],
           let service = root["gemini-cli-api-key"] as? [String: Any],
           let accountValue = service["default-api-key"] {
            // Inner value is usually a JSON string, occasionally a dict.
            if let str = accountValue as? String,
               let inner = str.data(using: .utf8),
               let entry = (try? JSONSerialization.jsonObject(with: inner)) as? [String: Any],
               let accessToken = accessToken(in: entry) {
                return accessToken
            }
            if let entry = accountValue as? [String: Any],
               let accessToken = accessToken(in: entry) {
                return accessToken
            }
        }

        return nil
    }

    private static func accessToken(in entry: [String: Any]) -> String? {
        guard let token = entry["token"] as? [String: Any],
              let accessToken = token["accessToken"] as? String,
              !accessToken.isEmpty
        else { return nil }
        return accessToken
    }

    /// Serialize a Swift string into a safe JS string literal (including quotes).
    private static func jsStringLiteral(_ s: String) -> String {
        let encoded = (try? JSONSerialization.data(
            withJSONObject: [s],
            options: [.fragmentsAllowed]
        )) ?? Data("[\"\"]".utf8)
        let wrapped = String(data: encoded, encoding: .utf8) ?? "[\"\"]"
        return String(wrapped.dropFirst().dropLast())
    }
}
