// The firebase plugin's extension (`runtime: extension`): its widgets run in their own process.
import SwiftUI
import Work42Extension
import Work42PluginKit

/// `nonisolated` is required: ExtensionKit makes this class off the main actor (the widgets stay on it).
@main
nonisolated final class FirebaseExtension: Work42PluginExtension {
    required init() {}

    @MainActor var widgets: [ExtensionWidgetFactory] {
        [
            ExtensionWidgetFactory("firebase-analytics") { FirebaseConsoleWidget(product: .analytics) },
            ExtensionWidgetFactory("firebase-auth") { FirebaseConsoleWidget(product: .auth) },
            ExtensionWidgetFactory("firebase-crashlytics") { FirebaseConsoleWidget(product: .crashlytics) },
            ExtensionWidgetFactory("firebase-firestore") { FirebaseConsoleWidget(product: .firestore) },
        ]
    }
}
