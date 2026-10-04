import Foundation
import Testing

@Suite("Task42 optional Flow42 consumption")
struct Task42FlowConsumerContractTests {
    struct Reference: Equatable {
        let flow: String
        let variant: String?
        let config: String?

        var link: String? {
            guard let variant else { return nil }
            return "[\(flow) / \(variant)](flow42://flow/\(flow)?variant=\(variant))"
        }
    }

    @Test("flow and variant are separate mandatory fields")
    func explicitSelection() throws {
        let valid = references(in: try fixture("single.md"))
        #expect(valid == [.init(flow: "login", variant: "browser", config: "Web QA")])
        #expect(valid[0].link == "[login / browser](flow42://flow/login?variant=browser)")

        let invalid = references(in: try fixture("missing-variant.md"))
        #expect(invalid.count == 1)
        #expect(invalid[0].variant == nil)
        #expect(invalid[0].link == nil)
    }

    @Test("multi-platform coverage repeats one conceptual flow per variant")
    func multiVariantCoverage() throws {
        let values = references(in: try fixture("multi.md"))
        #expect(values.map(\.flow) == ["login", "login", "login"])
        #expect(values.compactMap(\.variant) == ["browser", "ios", "android"])
        #expect(Set(values.compactMap(\.config)) == ["Web QA", "iOS QA", "Android QA"])
    }

    @Test("planner and QA publish the explicit coverage contract")
    func skillContracts() throws {
        let planner = collapsed(try source("task42/skills/task42-planner/SKILL.md"))
        let qa = collapsed(try source("task42/skills/task42-qa/SKILL.md"))
        let author = collapsed(try source("task42/skills/flow42-qa-author/SKILL.md"))
        for skill in [planner, qa, author] {
            #expect(skill.contains("flow: login"))
            #expect(skill.contains("variant: browser"))
        }
        #expect(planner.contains("repeat the entry"))
        #expect(qa.lowercased().contains("work42—not task42 or the plan—selects the concrete compatible"))
        #expect(author.lowercased().contains("work42 selects the concrete compatible registered device"))
    }

    @Test("Task42 remains installable and renderable without Flow42")
    func optionalPluginBoundary() throws {
        let sessionType = try source("task42/session-types/task.json")
        let widget = try source("task42/widgets/testing-plan/Sources/Widget.swift")
        let manifest = try source("task42/plugin.yaml")
        #expect(sessionType.contains("\"flow42-qa-author\""))
        #expect(manifest.contains("name: task42"))
        #expect(!manifest.contains("global_skills:"))
        #expect(widget.contains("Work42MarkdownDocument"))
        #expect(!widget.contains("import Flow42"))
        #expect(!widget.contains("FlowDefinition"))
    }

    @Test("QA retains ordinary Work42 recording evidence grammar")
    func recordingEvidence() throws {
        let qa = collapsed(try source("task42/skills/task42-qa/SKILL.md"))
        #expect(qa.contains("work42 device start"))
        #expect(qa.contains("work42 device stop"))
        #expect(qa.contains("frame:<recording-slug>#<eventNumber>"))
        #expect(qa.contains("### flow: <recording-slug>"))
        #expect(qa.contains("existing Work42 recording card"))
        #expect(!qa.contains("`flow42 play"))
        #expect(!qa.contains("`flow42 view"))
    }

    private func references(in markdown: String) -> [Reference] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [Reference] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- flow:") else { index += 1; continue }
            let flow = trimmed.dropFirst("- flow:".count).trimmingCharacters(in: .whitespaces)
            var variant: String?
            var config: String?
            index += 1
            while index < lines.count {
                let raw = lines[index]
                let next = raw.trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("- flow:") || (!raw.hasPrefix(" ") && !next.isEmpty) { break }
                if next.hasPrefix("variant:") {
                    variant = next.dropFirst("variant:".count).trimmingCharacters(in: .whitespaces)
                } else if next.hasPrefix("config:") {
                    config = next.dropFirst("config:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                }
                index += 1
            }
            result.append(.init(flow: flow, variant: variant, config: config))
        }
        return result
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }
    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!, encoding: .utf8)
    }
    private func collapsed(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
