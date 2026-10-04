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

    @Test("catalog orders variants and derives preview counts deterministically")
    func catalogOrderingAndPreview() throws {
        let temporary = makeTemporaryRegistry()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeFlow(
            root: temporary,
            id: "publish",
            variants: ["zebra", "android", "browser", "ios", "alpha"]
        )

        let items = FlowDefinitionLoader(registryRoot: temporary).list()
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.orderedVariants == ["browser", "ios", "android", "alpha", "zebra"])
        #expect(item.preview?.selection.variant == "browser")
        #expect(item.variantCount == 5)
        #expect(item.previewStepCount == 1)
        #expect(item.warning == nil)
    }

    @Test("missing and empty registries return an empty catalog")
    func emptyCatalog() throws {
        let temporary = makeTemporaryRegistry(create: false)
        #expect(FlowDefinitionLoader(registryRoot: temporary).list().isEmpty)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect(FlowDefinitionLoader(registryRoot: temporary).list().isEmpty)
    }

    @Test("malformed siblings remain visible beside valid flows")
    func malformedSibling() throws {
        let temporary = makeTemporaryRegistry()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeFlow(root: temporary, id: "healthy", variants: ["browser"])
        let broken = temporary.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "id: wrong\nvariants:\n  browser: browser/flow.yaml\n"
            .write(to: broken.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)

        let items = FlowDefinitionLoader(registryRoot: temporary).list()
        #expect(items.map(\.id) == ["broken", "healthy"])
        #expect(items[0].warning?.field == "catalog")
        #expect(items[0].warning?.message.contains("Manifest id") == true)
        #expect(items[1].preview != nil)
    }

    @Test("catalog rejects traversal and symlink escapes as named warnings")
    func catalogContainment() throws {
        let temporary = makeTemporaryRegistry()
        let outside = makeTemporaryRegistry()
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: outside)
        }

        let traversal = temporary.appendingPathComponent("traversal", isDirectory: true)
        try FileManager.default.createDirectory(at: traversal, withIntermediateDirectories: true)
        try "id: traversal\nvariants:\n  browser: ../outside.yaml\n"
            .write(to: traversal.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)

        try writeFlow(root: outside, id: "linked", variants: ["browser"])
        try FileManager.default.createSymbolicLink(
            at: temporary.appendingPathComponent("linked"),
            withDestinationURL: outside.appendingPathComponent("linked")
        )

        let items = FlowDefinitionLoader(registryRoot: temporary).list()
        #expect(items.map(\.id) == ["linked", "traversal"])
        #expect(items.allSatisfy { $0.warning?.message.contains("escapes") == true })
    }

    @Test("Markdown renderer output is stable and complete")
    func markdownGolden() throws {
        let definition = try loader.load(.init(flow: "login", variant: "browser"))
        let rendered = FlowDefinitionMarkdownRenderer.render(definition)
        let expected = """
        # Log In

        Authenticate an existing user.

        - **Flow:** `login`
        - **Variant:** `browser`
        - **Device:** `browser`
        - **Tags:** `authentication`

        ## Inputs

        | Parameter | Type | Description |
        | --- | --- | --- |
        | `email` | string | Account email address. |

        ## 1. authenticate

        Authenticate the account.

        ### Step 1

        **Action:** `type`

        | Argument | Value |
        | --- | --- |
        | `clear` | `true` |
        | `label` | `Email` |
        | `role` | `textbox` |
        | `text` | `${email}` |

        **Before:** The sign-in form is visible.

        **Expected:** The Email field contains the requested address.

        ![Visual guidance — state immediately before the action](references/authenticate-01.png)

        *Visual guidance · state immediately before the action*

        ### Step 2

        **Action:** `click`

        | Argument | Value |
        | --- | --- |
        | `label` | `Continue` |
        | `role` | `button` |

        **Before:** The form contains a valid email address.

        **Expected:** The password step is visible.

        """
        #expect(rendered == expected)
    }

    @Test("Markdown escapes authored syntax and omits missing screenshots")
    func markdownEscapingAndScreenshots() throws {
        let broken = try loader.load(.init(flow: "login", variant: "broken"))
        let brokenMarkdown = FlowDefinitionMarkdownRenderer.render(broken)
        #expect(!brokenMarkdown.contains("!["))
        #expect(brokenMarkdown.contains("## Definition warnings"))

        let definition = FlowDefinition(
            selection: .init(flow: "special", variant: "browser"),
            manifest: .init(
                id: "special",
                name: "# Heading [link]",
                description: "Uses *authored* | syntax.",
                tags: [],
                variants: ["browser": "browser/flow.yaml"]
            ),
            device: "browser",
            parameters: [],
            phases: [],
            warnings: [],
            directory: fixtures
        )
        let rendered = FlowDefinitionMarkdownRenderer.render(definition)
        #expect(rendered.contains("# \\# Heading \\[link\\]"))
        #expect(rendered.contains("Uses \\*authored\\* \\| syntax."))
    }

    @Test("comment keys are stable and variant-specific")
    func commentKeys() throws {
        let browser = try loader.load(.init(flow: "login", variant: "browser"))
        let broken = try loader.load(.init(flow: "login", variant: "broken"))
        #expect(browser.commentKey == "flow42/flows/login/browser")
        #expect(broken.commentKey == "flow42/flows/login/broken")
        #expect(browser.commentKey != broken.commentKey)
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

    private func makeTemporaryRegistry(create: Bool = true) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow42-catalog-\(UUID().uuidString)", isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private func writeFlow(root: URL, id: String, variants: [String]) throws {
        let family = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: family, withIntermediateDirectories: true)
        let variantLines = variants.map { "  \($0): \($0)/flow.yaml" }.joined(separator: "\n")
        try "id: \(id)\nname: \(id.capitalized)\nvariants:\n\(variantLines)\n"
            .write(to: family.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
        for variant in variants {
            let directory = family.appendingPathComponent(variant, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try """
            device: \(variant)
            phases:
              - id: verify
                steps:
                  - action: click
                    arguments:
                      label: Continue
                    precondition: Ready.
                    postcondition: Done.

            """.write(to: directory.appendingPathComponent("flow.yaml"), atomically: true, encoding: .utf8)
        }
    }
}
