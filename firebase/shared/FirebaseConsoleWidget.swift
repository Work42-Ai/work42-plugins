// FirebaseConsoleWidget.swift — one Firebase product's Console page in an independent widget.
//
// Every Firebase widget is this class with a different `FirebaseProduct`. Its view is a native toolbar
// (current project + Set Project) above a BrowserSurface showing the product's live Firebase Console page.
//
//   • The project comes from the shared file (FirebaseProjectStore), never from widget or session storage.
//     Each widget library keeps its own store and follows the file, so nothing relies on a shared singleton.
//   • The toolbar lives outside the web content, so Set Project stays reachable through Google redirects.
//   • The browser navigates only when the selected project really changes; otherwise the user's own
//     Console navigation is left alone.
//   • dataStoreKey "browser" shares cookies with the Browser widget, so signing in once covers every
//     Firebase widget. That is the Console's Google sign-in, not the Firebase CLI's login.

import Observation
import SwiftUI
import Work42PluginKit

@Observable
@MainActor
final class FirebaseConsoleWidget: Work42Widget {

    let product: FirebaseProduct
    let store: FirebaseProjectStore

    var id: String { product.widgetId }
    var title: String { product.title }
    var icon: String { product.icon }

    /// Console pages are opened by this widget only; it doesn't claim links.
    var linkIntents: [WidgetLinkIntentSpec] { [] }

    @ObservationIgnored private(set) var services: SessionServices?
    /// The surface's model, saved from `configure:`.
    @ObservationIgnored var browserModel: BrowserWidgetModel?
    /// The project whose page the browser was last pointed at; nil until a page has been loaded.
    @ObservationIgnored private(set) var loadedProjectId: String?

    init(product: FirebaseProduct, store: FirebaseProjectStore = FirebaseProjectStore()) {
        self.product = product
        self.store = store
    }

    // MARK: Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        store.start()
    }

    func deactivate() {
        store.stop()
        services = nil
        browserModel = nil
        loadedProjectId = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(FirebaseConsoleView(widget: self, services: services))
    }

    // MARK: Navigation

    /// Called from the surface's `configure:`. `projectId` is the project the surface was built with.
    func surfaceMounted(_ model: BrowserWidgetModel, builtFor projectId: String) {
        browserModel = model
        if loadedProjectId == nil { loadedProjectId = projectId }
        navigateIfProjectChanged()
    }

    /// Points the browser at this product's page for the current selection, but only if the project changed.
    func navigateIfProjectChanged() {
        guard let model = browserModel,
              let target = product.navigationTarget(selected: store.state.projectId, loaded: loadedProjectId),
              let projectId = store.state.projectId else { return }
        loadedProjectId = projectId
        // A fresh tab id makes the surface build a new web view for the new project's URL.
        model.replaceTabs([BrowserTab(id: UUID(), url: target, title: product.title, icon: product.icon)])
    }

    // MARK: Project picker

    func makePickerModel() -> FirebaseProjectPickerModel? {
        guard let services else { return nil }
        let shell = services.shell
        return FirebaseProjectPickerModel(
            run: { command in
                let result = try await shell.run(command: command)
                return FirebaseShellResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
            },
            store: store)
    }
}

// MARK: - View

@MainActor
private struct FirebaseConsoleView: View {
    let widget: FirebaseConsoleWidget
    let services: SessionServices

    @State private var pickerModel: FirebaseProjectPickerModel?

    private var state: FirebaseProjectState { widget.store.state }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .sheet(isPresented: Binding(get: { pickerModel != nil }, set: { if !$0 { pickerModel = nil } })) {
            if let model = pickerModel {
                FirebaseProjectPickerSheet(model: model, currentProjectId: state.projectId) { pickerModel = nil }
            }
        }
        .onChange(of: state.projectId) { _, _ in widget.navigateIfProjectChanged() }
        .onAppear { widget.store.reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame").foregroundStyle(.orange)
            switch state {
            case .selected(let selection):
                VStack(alignment: .leading, spacing: 0) {
                    Text(selection.displayName).font(.callout).lineLimit(1)
                    if selection.displayName != selection.projectId {
                        Text(selection.projectId).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            case .none:
                Text("Select a Firebase project").font(.callout).foregroundStyle(.secondary)
            case .invalid:
                Text("Firebase project file needs repair").font(.callout).foregroundStyle(.red)
            }
            Spacer()
            Button("Set Project") { pickerModel = widget.makePickerModel() }
                .disabled(pickerModel != nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .selected(let selection):
            if let url = widget.product.consoleURL(projectId: selection.projectId) {
                BrowserSurface(
                    spec: BrowserSurfaceSpec(url: url, selector: "", dataStoreKey: "browser",
                                             title: widget.product.title, icon: widget.product.icon),
                    cacheKey: widget.id,
                    configure: { [weak widget] model in
                        widget?.surfaceMounted(model, builtFor: selection.projectId)
                    })
            } else {
                message("“\(selection.projectId)” isn't a usable project ID. Choose a project to continue.")
            }
        case .none:
            message("Choose the Firebase project this widget should show. The choice is shared by every Firebase widget.")
        case .invalid(let why):
            message(why)
        }
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
