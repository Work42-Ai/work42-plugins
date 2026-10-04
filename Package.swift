// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Work42Plugins",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PluginLinkSupport", targets: ["PluginLinkSupport"]),
        .library(name: "Flow42DefinitionCore", targets: ["Flow42DefinitionCore"]),
    ],
    targets: [
        .target(
            name: "PluginLinkSupport",
            path: ".",
            exclude: [
                "LICENSE",
                "README.md",
                "Tests",
                "default.profraw",
                "github/README.md",
                "github/plugin.yaml",
                "github/skills",
                "github/tab-templates",
                "github/widgets/github/SKILL.md",
                "github/widgets/github/Sources/Widget.swift",
                "github/widgets/github-prs",
                "jira/README.md",
                "jira/plugin.yaml",
                "jira/skills",
                "jira/tab-templates",
                "jira/widgets/jira/SKILL.md",
                "jira/widgets/jira/Sources/Widget.swift",
                "jira/widgets/jira-my-issues",
                "figma/README.md",
                "figma/plugin.yaml",
                "figma/skills",
                "figma/tab-templates",
                "figma/widgets/figma/SKILL.md",
                "figma/widgets/figma/Sources/Widget.swift",
                "task42/README.md",
                "task42/plugin.yaml",
                "task42/skills",
                "task42/workflows/task42.json",
                "task42/session-types/task.json",
                "task42/intents/new-task.json",
                "task42/Sources/Plugin.swift",
                "task42/widgets/spec/SKILL.md",
                "task42/widgets/spec/Sources/Widget.swift",
                "task42/widgets/subtasks/SKILL.md",
                "task42/widgets/subtasks/Sources/Widget.swift",
                "task42/widgets/qa/SKILL.md",
                "task42/widgets/qa/Sources/Widget.swift",
                "task42/widgets/testing-plan/SKILL.md",
                "task42/widgets/testing-plan/Sources/Widget.swift",
                "flow42",
                // patrol42 ships no compiled LinkSupport (it reuses the github
                // plugin's widget) — its Plugin.swift compiles at install time,
                // so the whole bundle is excluded from this package build.
                "patrol42",
            ],
            sources: [
                "github/widgets/github/Sources/GitHubLinkSupport.swift",
                "jira/widgets/jira/Sources/JiraLinkSupport.swift",
            ]
        ),
        .testTarget(
            name: "PluginLinkSupportTests",
            dependencies: ["PluginLinkSupport"],
            path: "Tests/PluginLinkSupportTests"
        ),
        .testTarget(
            name: "Flow42CreatorContractTests",
            path: "Tests/Flow42CreatorContractTests",
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "Flow42DefinitionCore",
            path: "flow42/widgets/flow-definition/Sources",
            exclude: ["FlowDefinitionView.swift", "Widget.swift"]
        ),
        .testTarget(
            name: "Flow42PlayerWidgetTests",
            dependencies: ["Flow42DefinitionCore"],
            path: "Tests/Flow42PlayerWidgetTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
