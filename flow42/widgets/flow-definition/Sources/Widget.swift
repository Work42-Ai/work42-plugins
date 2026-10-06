import Observation
import SwiftUI
import Work42WidgetKit

@Observable
@MainActor
final class FlowDefinitionWidget: Work42Widget {
    let id = "flow-definition"
    let title = "Flows"
    let icon = "point.topleft.down.to.point.bottomright.curvepath"
    var contentPadding: Double { 0 }

    let navigation = FlowDefinitionNavigation()
    private var services: SessionServices?

    var linkIntents: [WidgetLinkIntentSpec] {
        [WidgetLinkIntentSpec(
            matchers: [.regex(#"^flow42://flow/[a-z0-9]+(?:-[a-z0-9]+)*(?:\?.*)?$"#)],
            perform: { [weak self] url in self?.open(url) }
        )]
    }

    func activate(services: SessionServices) {
        self.services = services
        navigation.reloadCatalog()
    }

    func deactivate() {
        services = nil
        navigation.back()
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(FlowDefinitionView(navigation: navigation, services: services))
    }

    func makeHeaderView() -> AnyView {
        AnyView(FlowDefinitionHeader(navigation: navigation))
    }

    private func open(_ url: URL) {
        do {
            let selection = try FlowSelection.parse(url)
            navigation.open(selection)
        } catch {
            navigation.showLinkError(error.localizedDescription)
        }
    }
}

extension FlowDefinitionWidget: Work42WidgetCustomHeader {}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(FlowDefinitionWidget()) }
    return result
}
