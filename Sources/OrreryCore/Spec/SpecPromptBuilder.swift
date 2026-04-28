import Foundation

public struct SpecPromptBuilder {

    public static func buildPrompt(
        inputContent: String,
        template: SpecTemplate,
        projectContext: String?
    ) -> String {
        var lines: [String] = []

        lines.append("You are a spec writer. Convert the following discussion/report into a structured implementation spec.")
        lines.append("")
        lines.append("## Template Structure")
        lines.append("The spec MUST follow this exact structure:")
        lines.append("")
        for section in template.sections {
            lines.append("### \(section.title)")
            lines.append(section.instruction)
            lines.append("Required: \(section.required ? "yes" : "no")")
            lines.append("")
        }

        lines.append("## Input Document")
        lines.append(inputContent)

        if let context = projectContext {
            lines.append("")
            lines.append("## Project Context")
            lines.append(context)
        }

        lines.append("")
        lines.append("## Instructions")
        lines.append("- Output the complete spec in Markdown. Follow the template structure exactly.")
        lines.append("- Use the language of the input document (if input is Chinese, write spec in Chinese).")
        lines.append("- Every required section must be present and substantive.")
        lines.append("- Mark inferred content (not explicitly stated in the input) with [inferred].")
        lines.append("- Do NOT include these instructions or meta-commentary in the output.")

        return lines.joined(separator: "\n")
    }
}

public struct SpecReviewPromptBuilder {

    public static func buildReviewPrompt(
        specContent: String,
        originalInput: String,
        template: SpecTemplate
    ) -> String {
        var lines: [String] = []

        lines.append("You are a spec reviewer. Review the following spec for completeness and correctness.")
        lines.append("")
        lines.append("## Spec to Review")
        lines.append(specContent)
        lines.append("")
        lines.append("## Original Input")
        lines.append(originalInput)
        lines.append("")
        lines.append("## Expected Template Structure")
        for section in template.sections {
            lines.append("- \(section.title) (required: \(section.required))")
        }
        lines.append("")
        lines.append("## Review Checklist")
        lines.append("1. All decisions from the input are covered in the spec")
        lines.append("2. Interface signatures are reasonable and complete")
        lines.append("3. Failure paths are not missing")
        lines.append("4. Acceptance criteria are testable with executable commands")
        lines.append("5. No required section is empty or placeholder-only")
        lines.append("")
        lines.append("If the spec needs fixes, output the corrected full spec.")
        lines.append("If no changes are needed, output exactly: [LGTM]")

        return lines.joined(separator: "\n")
    }
}
