// The linear42 plugin's extension (`runtime: extension`): its widgets and session hooks run in their own process.
import SwiftUI
import Work42Extension
import Work42PluginKit

/// `nonisolated` is required: ExtensionKit makes this class off the main actor (the widgets stay on it).
@main
nonisolated final class Linear42Extension: Work42PluginExtension {
    required init() {}

    @MainActor var widgets: [ExtensionWidgetFactory] {
        [
            ExtensionWidgetFactory("linear-issue") { LinearIssueWidget() },
            ExtensionWidgetFactory("linear-my-issues") { LinearMyIssuesWidget() },
            ExtensionWidgetFactory("linear-qa") { LinearQAWidget() },
            ExtensionWidgetFactory("linear-spec") { LinearSpecWidget() },
            ExtensionWidgetFactory("linear-testing") { LinearTestingWidget() },
        ]
    }

    @MainActor var sessionHooks: (any Work42SessionHooks)? { Linear42Hooks() }
}
