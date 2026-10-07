// Widget.swift — linear42's Testing Plan widget.
//
// Renders the testing plan as the Linear Document the Planner attached to the
// issue (`linear/testing_doc`), in a BrowserSurface on the user's linear.app
// login. Read-only: the Planner authors the document with the `linear` CLI.
//
// STORAGE (storageNamespace "linear"):
//   linear/testing_doc — {slug,url}. Written by the Planner after
//                        `linear document create`.

import Foundation
import Observation
import SwiftUI
import Work42PluginKit

/// `linear/testing_doc` — a Linear document reference.
struct LinearDocRef: Equatable, Sendable {
    var slug: String
    var url: URL

    init?(_ value: WidgetJSONValue?) {
        guard case .object(let o)? = value,
              case .string(let raw)? = o["url"], let url = URL(string: raw)
        else { return nil }
        self.url = url
        if case .string(let slug)? = o["slug"] { self.slug = slug } else { self.slug = "" }
    }
}

@Observable
@MainActor
final class LinearTestingWidget: Work42Widget {

    let id = "linear-testing"
    let title = "Testing Plan Document"
    let icon = "testtube.2"
    /// The Linear logo in the + Widget menu, the tab and the header; the symbol above is the fallback.
    var iconImageData: Data? { linearIconPNG }
    var storageNamespace: String? { "linear" }
    /// Links to this widget's pages open here (the tab is focused) instead of navigating the page they
    /// were clicked in. A link to the page already shown only focuses the tab.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [.regex(linearTestingDocLinkPattern)],
                perform: { [weak self] url in self?.openLink(url) }
            ),
        ]
    }

    var testingDoc: LinearDocRef?
    /// A document opened through a link (a different page than the stored one); nil shows `testingDoc`.
    var openedURL: URL?

    private var services: SessionServices?

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    func deactivate() {
        services = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(LinearTestingView(widget: self))
    }

    func openLink(_ url: URL) {
        openedURL = linkDestination(url, current: testingDoc?.url)
    }

    /// Assigns only on change so the view never re-renders for an unchanged poll.
    func refresh() async {
        guard let services else { return }
        let doc = LinearDocRef((try? await services.storage.get(namespace: "linear", key: "testing_doc")) ?? nil)
        if doc != testingDoc { testingDoc = doc; openedURL = nil }
    }
}

@MainActor
private struct LinearTestingView: View {
    let widget: LinearTestingWidget

    var body: some View {
        Group {
            if let doc = widget.testingDoc {
                let shown = widget.openedURL ?? doc.url
                BrowserSurface(
                    spec: BrowserSurfaceSpec(
                        url: shown,
                        selector: "",
                        dataStoreKey: "browser",
                        title: "Testing Plan Document",
                        icon: "testtube.2"
                    ),
                    cacheKey: widget.id
                )
                .id(shown.absoluteString)
            } else {
                VStack(alignment: .leading, spacing: DT.s8) {
                    LinearBrandMark(size: 28)
                    Text("No testing plan yet")
                        .font(.system(size: DT.f13, weight: .semibold))
                    Text("The Planner creates the testing plan as a Linear document on the issue. It appears here automatically.")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DT.s12)
                .padding(.top, DT.s12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // Live refresh while on screen: `linear/testing_doc` lands without reopening the tab.
        .task {
            await widget.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                if Task.isCancelled { break }
                await widget.refresh()
            }
        }
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(LinearTestingWidget())
    }
    return result
}
