// The patrol42 plugin's extension (`runtime: extension`): its widgets and session hooks run in their own process.
import SwiftUI
import Work42Extension
import Work42PluginKit

/// `nonisolated` is required: ExtensionKit makes this class off the main actor (the widgets and hooks stay on it).
@main
nonisolated final class Patrol42Extension: Work42PluginExtension {
    required init() {}

    @MainActor var widgets: [ExtensionWidgetFactory] {
        [

        ]
    }

    @MainActor var sessionHooks: (any Work42SessionHooks)? { Patrol42Hooks() }
}
