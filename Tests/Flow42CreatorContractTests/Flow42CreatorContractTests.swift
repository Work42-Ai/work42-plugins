import Foundation
import Testing

@Suite("Flow42 creator plugin contract")
struct Flow42CreatorContractTests {
    @Test("plugin declares exactly the two global skills and no runtime contributions")
    func minimalPlugin() throws {
        let plugin = try text(at: root.appendingPathComponent("flow42/plugin.yaml"))
        #expect(plugin.contains("global_skills: flow-creator, flow-player"))
        for absent in ["session-types", "workflows", "intents", "mcp", "Sources/Plugin.swift"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("flow42/\(absent)").path))
        }
    }

    @Test("new and updated fixtures keep one stable variant path")
    func createAndReplaceInPlace() throws {
        let newManifest = try fixture("new/manifest.yaml")
        let updatedManifest = try fixture("update/manifest.yaml")
        #expect(newManifest.contains("browser: browser/flow.yaml"))
        #expect(updatedManifest.contains("browser: browser/flow.yaml"))
        #expect(!updatedManifest.contains("revision"))
        #expect(!updatedManifest.contains("version_history"))
    }

    @Test("multi-recording synthesis emits one action and condition pair per step")
    func canonicalSteps() throws {
        for path in ["new/browser/flow.yaml", "update/browser/flow.yaml", "multi/ios/flow.yaml"] {
            let flow = try fixture(path)
            let actions = countIndented("- action:", in: flow)
            #expect(actions > 0)
            #expect(countIndented("precondition:", in: flow) == actions)
            #expect(countIndented("postcondition:", in: flow) == actions)
            #expect(!flow.contains("recording-a"))
            #expect(!flow.contains("recording-b"))
        }
    }

    @Test("saved definitions reject transient execution and provenance fields")
    func portableAndStandalone() throws {
        let fixtureRoot = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures"))
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixtureRoot.path)
            .filter { $0.hasSuffix(".yaml") }
        let forbidden = [
            "recording_id:", "recording_path:", "session_id:", "timestamp_ms:",
            "video:", " x:", " y:", " at:", " ref:", "geometry:", "command:",
        ]
        for file in files {
            let saved = try text(at: fixtureRoot.appendingPathComponent(file))
            for token in forbidden { #expect(!saved.contains(token)) }
            for line in saved.split(separator: "\n") where line.contains("screenshot:") {
                let value = line.split(separator: ":", maxSplits: 1)[1]
                    .trimmingCharacters(in: .whitespaces)
                #expect(value.hasPrefix("references/"))
                let parent = (file as NSString).deletingLastPathComponent
                let image = (parent as NSString).appendingPathComponent(value)
                #expect(FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent(image).path))
            }
        }
    }

    @Test("skill requires confirmation, replacement, and missing-device follow-up")
    func creatorWorkflow() throws {
        let skill = collapsedWhitespace(
            try text(at: root.appendingPathComponent("flow42/skills/flow-creator/SKILL.md"))
        ).lowercased()
        #expect(skill.contains("one or more completed work42 recording directories"))
        #expect(skill.contains("do not write anything until the user explicitly confirms"))
        #expect(skill.contains("updating a variant replaces its `flow.yaml` in place"))
        #expect(skill.contains("available classes absent from the manifest"))
        #expect(skill.contains("add no manifest entry or empty directory"))
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture(_ path: String) throws -> String {
        let fixtures = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures"))
        return try text(at: fixtures.appendingPathComponent(path))
    }

    private func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func countIndented(_ token: String, in text: String) -> Int {
        text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(token) }.count
    }

    private func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
