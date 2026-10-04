import Foundation
import Testing
@testable import Flow42DefinitionCore

@Suite("Flow42 player and definition widget")
struct Flow42PlayerWidgetTests {
    @Test("link requires separate explicit flow and variant")
    func explicitSelection() throws {
        let selected = try FlowSelection.parse(#require(URL(string: "flow42://flow/login?variant=browser")))
        #expect(selected == FlowSelection(flow: "login", variant: "browser"))
        #expect(throws: FlowDefinitionError.self) {
            try FlowSelection.parse(#require(URL(string: "flow42://flow/login")))
        }
        #expect(throws: FlowDefinitionError.self) {
            try FlowSelection.parse(#require(URL(string: "flow42://flow/login?variant=../ios")))
        }
    }

    @Test("loader follows manifest and renders structured definition")
    func definitionParsing() throws {
        let definition = try loader.load(.init(flow: "login", variant: "browser"))
        #expect(definition.manifest.name == "Log In")
        #expect(definition.device == "browser")
        #expect(definition.parameters.map(\.id) == ["email"])
        #expect(definition.phases.count == 1)
        #expect(definition.phases[0].steps.count == 2)
        #expect(definition.phases[0].steps[0].action == "type")
        #expect(definition.phases[0].steps[0].arguments.contains { $0 == ("label", "Email") })
        #expect(definition.phases[0].steps[0].screenshot != nil)
        #expect(definition.warnings.isEmpty)
    }

    @Test("malformed optional fields produce warnings without hiding the definition")
    func failSoftWarnings() throws {
        let definition = try loader.load(.init(flow: "login", variant: "broken"))
        #expect(definition.phases.count == 1)
        #expect(definition.phases[0].steps.count == 1)
        #expect(definition.warnings.contains { $0.field == "device" })
        #expect(definition.warnings.contains { $0.field.hasSuffix(".action") })
        #expect(definition.warnings.contains { $0.field.hasSuffix(".screenshot") })
    }

    @Test("undeclared and escaping variants are rejected")
    func safeVariantResolution() throws {
        #expect(throws: FlowDefinitionError.self) {
            try loader.load(.init(flow: "login", variant: "ios"))
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow42-escape-\(UUID().uuidString)")
        let family = temporary.appendingPathComponent("escape")
        try FileManager.default.createDirectory(at: family, withIntermediateDirectories: true)
        try "id: escape\nname: Escape\nvariants:\n  browser: ../outside.yaml\n"
            .write(to: family.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect(throws: FlowDefinitionError.self) {
            try FlowDefinitionLoader(registryRoot: temporary).load(.init(flow: "escape", variant: "browser"))
        }
    }

    @Test("player makes Work42 recording cleanup mandatory on every post-start exit")
    func recordingEnvelopeContract() throws {
        let skill = collapsed(try String(contentsOf: root.appendingPathComponent("flow42/skills/flow-player/SKILL.md"), encoding: .utf8)).lowercased()
        #expect(skill.contains("must successfully start work42 recording before the first flow action"))
        for exit in ["success", "failure", "cancellation", "action error", "agent exception"] {
            #expect(skill.contains(exit))
        }
        #expect(skill.contains("`work42 device stop` is mandatory before every return path"))
        #expect(skill.contains("never delete failed or cancelled evidence"))
        #expect(skill.contains("substitute another registered work42 action"))
        #expect(skill.contains("skip the action entirely"))
        #expect(skill.contains("never mutate the flow from a failed workaround"))
    }

    @Test("widget is definition-only and claims the canonical Flow42 URL")
    func widgetBoundary() throws {
        let widget = try String(contentsOf: root.appendingPathComponent("flow42/widgets/flow-definition/Sources/Widget.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("flow42/widgets/flow-definition/Sources/FlowDefinitionView.swift"), encoding: .utf8)
        #expect(widget.contains("flow42://flow/"))
        #expect(widget.contains("FlowSelection.parse"))
        for forbidden in ["run history", "playback", "recording card", "next step", "pause", "resume"] {
            #expect(!view.lowercased().contains(forbidden))
        }
    }

    private var fixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }
    private var loader: FlowDefinitionLoader { FlowDefinitionLoader(registryRoot: fixtures) }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func collapsed(_ value: String) -> String {
        value.split(whereSeparator: \ .isWhitespace).joined(separator: " ")
    }
}
