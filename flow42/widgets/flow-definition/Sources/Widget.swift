import Observation
import SwiftUI
import Work42WidgetKit

@Observable
@MainActor
final class FlowDefinitionWidget: Work42Widget {
    let id = "flow-definition"
    let title = "Flow"
    let icon = "point.topleft.down.to.point.bottomright.curvepath"

    var definition: FlowDefinition?
    var errorMessage: String?

    var linkIntents: [WidgetLinkIntentSpec] {
        [WidgetLinkIntentSpec(
            matchers: [.regex(#"^flow42://flow/[a-z0-9]+(?:-[a-z0-9]+)*(?:\?.*)?$"#)],
            perform: { [weak self] url in self?.open(url) }
        )]
    }

    func activate(services: SessionServices) {}
    func deactivate() {}

    func makeView(services: SessionServices) -> AnyView {
        AnyView(FlowDefinitionView(widget: self))
    }

    private func open(_ url: URL) {
        do {
            let selection = try FlowSelection.parse(url)
            definition = try FlowDefinitionLoader().load(selection)
            errorMessage = nil
        } catch {
            definition = nil
            errorMessage = error.localizedDescription
        }
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(FlowDefinitionWidget()) }
    return result
}
