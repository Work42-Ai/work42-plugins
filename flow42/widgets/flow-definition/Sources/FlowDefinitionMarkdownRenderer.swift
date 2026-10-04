import Foundation

struct FlowDefinitionMarkdownRenderer {
    static func render(_ definition: FlowDefinition) -> String {
        var lines: [String] = []
        let manifest = definition.manifest

        lines.append("# \(text(manifest.name))")
        lines.append("")
        if let description = manifest.description, !description.isEmpty {
            lines.append(text(description))
            lines.append("")
        }
        lines.append("- **Flow:** \(code(manifest.id))")
        lines.append("- **Variant:** \(code(definition.selection.variant))")
        lines.append("- **Device:** \(code(definition.device.isEmpty ? "Not specified" : definition.device))")
        if !manifest.tags.isEmpty {
            lines.append("- **Tags:** \(manifest.tags.map(code).joined(separator: ", "))")
        }

        if !definition.warnings.isEmpty {
            lines.append("")
            lines.append("## Definition warnings")
            lines.append("")
            for warning in definition.warnings {
                lines.append("- **\(text(warning.field))** — \(text(warning.message))")
            }
        }

        if !definition.parameters.isEmpty {
            lines.append("")
            lines.append("## Inputs")
            lines.append("")
            lines.append("| Parameter | Type | Description |")
            lines.append("| --- | --- | --- |")
            for parameter in definition.parameters {
                lines.append("| \(code(parameter.id)) | \(table(parameter.type ?? "—")) | \(table(parameter.description ?? "—")) |")
            }
        }

        for (phaseIndex, phase) in definition.phases.enumerated() {
            lines.append("")
            lines.append("## \(phaseIndex + 1). \(text(phase.id))")
            if let intent = phase.intent, !intent.isEmpty {
                lines.append("")
                lines.append(text(intent))
            }
            for (stepIndex, step) in phase.steps.enumerated() {
                lines.append("")
                lines.append("### Step \(stepIndex + 1)")
                lines.append("")
                lines.append("**Action:** \(code(step.action ?? "Missing action"))")
                if !step.arguments.isEmpty {
                    lines.append("")
                    lines.append("| Argument | Value |")
                    lines.append("| --- | --- |")
                    for (key, value) in step.arguments {
                        lines.append("| \(code(key)) | \(code(value)) |")
                    }
                }
                lines.append("")
                lines.append("**Before:** \(text(step.precondition ?? "Not specified"))")
                lines.append("")
                lines.append("**Expected:** \(text(step.postcondition ?? "Not specified"))")
                if let screenshot = step.screenshot,
                   let relative = relativePath(from: definition.directory, to: screenshot) {
                    lines.append("")
                    lines.append("![Visual guidance — state immediately before the action](\(markdownPath(relative)))")
                    lines.append("")
                    lines.append("*Visual guidance · state immediately before the action*")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func text(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
        let special = CharacterSet(charactersIn: #"\`*_{}[]<>#+!|"#)
        return flattened.unicodeScalars.map { scalar in
            special.contains(scalar) ? "\\\(Character(scalar))" : String(Character(scalar))
        }.joined()
    }

    private static func table(_ value: String) -> String {
        text(value)
    }

    private static func code(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        var longestRun = 0
        var currentRun = 0
        for character in flattened {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: max(1, longestRun + 1))
        return "\(fence)\(flattened)\(fence)"
    }

    private static func relativePath(from directory: URL, to file: URL) -> String? {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let target = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard target.hasPrefix(base + "/") else { return nil }
        return String(target.dropFirst(base.count + 1))
    }

    private static func markdownPath(_ relative: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return relative.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }
}
