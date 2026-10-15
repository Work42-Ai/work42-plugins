// Widget.swift — firebase-analytics. The widget itself is FirebaseConsoleWidget (copied in from firebase/shared by
// scripts/sync-widget-sources.py); this file only picks the product and exports the loader's two symbols.

import Work42PluginKit

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(FirebaseConsoleWidget(product: .analytics))
    }
    return result
}
