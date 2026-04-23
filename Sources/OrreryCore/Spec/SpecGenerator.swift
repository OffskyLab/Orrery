import ArgumentParser
import Foundation

public struct SpecGenerator {

    public static func generate(
        inputPath: String,
        outputPath: String?,
        profile: String?,
        tool: Tool?,
        review: Bool,
        environment: String?,
        store: EnvironmentStore
    ) throws -> String {
        let fm = FileManager.default

        // 1. Read input
        let inputURL = URL(fileURLWithPath: inputPath)
        guard fm.fileExists(atPath: inputURL.path) else {
            throw ValidationError(L10n.Spec.inputNotFound(inputPath))
        }
        let inputContent = try String(contentsOf: inputURL, encoding: .utf8)

        // 2. Resolve profile
        let template = try SpecProfileResolver.resolve(profileName: profile, store: store)

        // 3. Optional project context (CLAUDE.md)
        let claudeMd = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("CLAUDE.md")
        let projectContext = try? String(contentsOf: claudeMd, encoding: .utf8)

        // 4. Build prompt
        let prompt = SpecPromptBuilder.buildPrompt(
            inputContent: inputContent, template: template, projectContext: projectContext)

        // 5. Select writer tool
        let writerTool = try tool ?? firstAvailableTool()
        stderr(L10n.Spec.generating(writerTool.rawValue))

        // 6. Call writer
        var specContent = try callTool(writerTool, prompt: prompt, environment: environment, store: store)

        // 7. Optional review
        if review {
            if let reviewerTool = try? firstAvailableTool(excluding: writerTool) {
                stderr(L10n.Spec.reviewing(reviewerTool.rawValue))
                let reviewPrompt = SpecReviewPromptBuilder.buildReviewPrompt(
                    specContent: specContent, originalInput: inputContent, template: template)
                let reviewOutput = try callTool(reviewerTool, prompt: reviewPrompt, environment: environment, store: store)
                if !reviewOutput.contains("[LGTM]") {
                    specContent = reviewOutput
                }
            } else {
                stderr("Only one tool available, skipping review.")
            }
        }

        // 8. Derive output path
        let outputURL: URL
        if let outputPath {
            outputURL = URL(fileURLWithPath: outputPath)
        } else if inputPath.contains("discussions/") {
            outputURL = URL(fileURLWithPath:
                inputPath.replacingOccurrences(of: "discussions/", with: "tasks/"))
        } else {
            let inputName = inputURL.lastPathComponent
            outputURL = URL(fileURLWithPath: "docs/tasks/\(inputName)")
        }

        // 9. Ensure output directory exists
        let outputDir = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // 10. Write spec
        try specContent.write(to: outputURL, atomically: true, encoding: .utf8)
        stderr(L10n.Spec.generated(outputURL.path))

        return outputURL.path
    }

    // MARK: - Private

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func firstAvailableTool(excluding: Tool? = nil) throws -> Tool {
        for tool in Tool.allCases where tool != excluding {
            if isToolAvailable(tool) { return tool }
        }
        throw ValidationError(L10n.Spec.noToolAvailable)
    }

    private static func isToolAvailable(_ tool: Tool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool.rawValue]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func callTool(
        _ tool: Tool, prompt: String,
        environment: String?, store: EnvironmentStore
    ) throws -> String {
        let builder = DelegateProcessBuilder(
            tool: tool, prompt: prompt,
            resumeSessionId: nil,
            environment: environment, store: store)
        let (process, _, outputPipe) = try builder.build(outputMode: .capture)

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Read stdout and stderr on background threads to avoid deadlock
        var stdoutData = Data()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global().async {
            if let pipe = outputPipe {
                stdoutData = pipe.fileHandleForReading.readDataToEndOfFile()
            }
            readGroup.leave()
        }

        let stderrGroup = DispatchGroup()
        stderrGroup.enter()
        DispatchQueue.global().async {
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrGroup.leave()
        }

        try process.run()
        process.waitUntilExit()
        readGroup.wait()
        stderrGroup.wait()

        return (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
