// The flow42 plugin's extension (`runtime: extension`): its widgets run in their own process.
import SwiftUI
import Work42Extension
import Work42PluginKit

/// `nonisolated` is required: ExtensionKit makes this class off the main actor (the widgets stay on it).
@main
nonisolated final class Flow42Extension: Work42PluginExtension {
    required init() {}

    @MainActor var widgets: [ExtensionWidgetFactory] {
        [
            ExtensionWidgetFactory("flow-definition") { FlowDefinitionWidget() },
        ]
    }
}
