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

    @Test("navigation covers library, detail, variant failure, deep link, and back")
    @MainActor
    func navigationStates() throws {
        let temporary = makeTemporaryRegistry()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeFlow(root: temporary, id: "publish", variants: ["ios", "browser"])
        let brokenURL = temporary.appendingPathComponent("publish/ios/flow.yaml")
        try FileManager.default.removeItem(at: brokenURL)

        let navigation = FlowDefinitionNavigation(loader: .init(registryRoot: temporary))
        navigation.reloadCatalog()
        #expect(navigation.catalog.count == 1)
        #expect(navigation.page == .library)

        navigation.select(try #require(navigation.catalog.first))
        guard case .detail(let browser) = navigation.page else {
            Issue.record("selecting a valid card must enter detail")
            return
        }
        #expect(browser.selectedVariant == "browser")
        #expect(browser.definition != nil)

        navigation.selectVariant("ios")
        guard case .detail(let failed) = navigation.page else {
            Issue.record("variant failure must remain in detail")
            return
        }
        #expect(failed.selectedVariant == "ios")
        #expect(failed.definition == nil)
        #expect(failed.errorMessage?.contains("Choose another") == true)

        navigation.open(.init(flow: "publish", variant: "browser"))
        guard case .detail(let linked) = navigation.page else {
            Issue.record("deep link must enter detail")
            return
        }
        #expect(linked.definition?.selection.variant == "browser")

        navigation.back()
        #expect(navigation.page == .library)
    }

    @Test("passive navigation and rendering never mutate the registry")
    @MainActor
    func passiveNoWriteContract() throws {
        let temporary = makeTemporaryRegistry()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeFlow(root: temporary, id: "read-only", variants: ["browser", "ios"])
        let before = try registrySnapshot(temporary)

        let navigation = FlowDefinitionNavigation(loader: .init(registryRoot: temporary))
        navigation.reloadCatalog()
        navigation.select(try #require(navigation.catalog.first))
        if case .detail(let detail) = navigation.page, let definition = detail.definition {
            _ = FlowDefinitionMarkdownRenderer.render(definition)
        }
        navigation.selectVariant("ios")
        navigation.back()

        #expect(try registrySnapshot(temporary) == before)
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

    @Test("widget composes the approved passive library and commentable detail surfaces")
    func widgetBoundary() throws {
        let widget = try String(contentsOf: root.appendingPathComponent("flow42/widgets/flow-definition/Sources/Widget.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("flow42/widgets/flow-definition/Sources/FlowDefinitionView.swift"), encoding: .utf8)
        let header = try String(contentsOf: root.appendingPathComponent("flow42/widgets/flow-definition/Sources/FlowDefinitionHeader.swift"), encoding: .utf8)

        #expect(widget.contains("flow42://flow/"))
        #expect(widget.contains("FlowSelection.parse"))
        #expect(widget.contains("let title = \"Flows\""))
        #expect(widget.contains("Work42WidgetCustomHeader"))
        #expect(view.contains("LazyVGrid"))
        #expect(view.contains("MarkdownPreview"))
        #expect(view.contains("Work42MarkdownDocument"))
        #expect(view.contains("artifactsEnabled: false"))
        #expect(view.contains("commentWidget: .init"))
        #expect(view.contains("slug: \"flow-definition\""))
        #expect(view.contains("detail.name) · \\(detail.selectedVariant.capitalized)"))
        #expect(view.contains(".allowsHitTesting(false)"))
        #expect(header.contains("GlassTabStrip"))
        #expect(header.contains("Back to Flows"))
        #expect(header.contains("case .library:\n                Text(\"Flows\")"))
        #expect(header.contains("Spacer(minLength: 0)"))
        #expect(view.contains("VStack(spacing: DT.s16)"))
        #expect(view.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        #expect((widget + view + header).contains("accessibilityLabel"))

        let surface = (widget + view + header).lowercased()
        for forbidden in [
            "run history", "playback", "recording card", "next step", "pause", "resume",
            "services.storage.set", "services.storage.delete", "services.shell",
            "button(\"run", "button(\"record", "button(\"edit", "button(\"delete",
        ] {
            #expect(!surface.contains(forbidden))
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

    private func registrySnapshot(_ root: URL) throws -> [String: Data] {
        let manager = FileManager.default
        let enumerator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var snapshot: [String: Data] = [:]
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                snapshot[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return snapshot
    }
}
