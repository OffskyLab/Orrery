import Foundation

public class TeeCapture: @unchecked Sendable {
    public let pipe = Pipe()
    private var buffer = Data()

    public init() {}

    public func start(forwardTo realStdout: FileHandle) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            realStdout.write(data)
            self?.buffer.append(data)
        }
    }

    public func finish() -> String {
        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty {
            buffer.append(remaining)
        }
        let raw = String(data: buffer, encoding: .utf8) ?? ""
        return Self.stripAnsi(raw)
    }

    static func stripAnsi(_ text: String) -> String {
        // Remove SGR and other CSI sequences: ESC[...X
        let pattern = "\u{1B}\\[[0-9;]*[a-zA-Z]"
        var result = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        // Remove carriage returns (Codex spinner cleanup)
        result = result.replacingOccurrences(of: "\r", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
