// FirebaseConsoleWidget.swift — one Firebase product's Console pages in an independent widget.
//
// Every Firebase widget is this class with a different `FirebaseProduct`. Its view is a BrowserSurface with
// one tab per project in the shared list (~/.work42/firebase/config.json), each opened on this product's
// Console page, and a small floating Liquid Glass "Projects" button at the bottom right that opens the
// project selection window.
//
//   • The project list is the file, never widget or session storage. Each widget library keeps its own
//     FirebaseProjectStore and follows the file, so nothing relies on a shared singleton.
//   • Tabs get stable ids per project, so an unchanged list never reloads a page, and the widget keeps its
//     own selected tab. The tab rules live in FirebaseTabs (pure, tested).
//   • Closing a tab with × hides that project in this widget only; hidden tabs return when the shared
//     list changes or Work42 restarts. The browser chrome's + opens the selection window.
//   • dataStoreKey "browser" shares cookies with the Browser widget, so signing in once covers every
//     Firebase widget. That is the Console's Google sign-in, not the Firebase CLI's login.

import AppKit
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
    var iconImageData: Data? { product.iconPNG }

    /// Console links are claimed in WOR-206; until then the Browser opens them.
    var linkIntents: [WidgetLinkIntentSpec] { [] }

    /// Projects whose tab this widget hid with ×.
    private(set) var hidden: Set<String> = []
    /// A link tab for a project that isn't in the shared list. Never written to the file.
    private(set) var temporary: FirebaseTemporaryTab?
    /// The open selection window's model, nil when it is closed.
    var selectionModel: FirebaseProjectPickerModel?

    @ObservationIgnored private(set) var services: SessionServices?
    /// The surface's model, saved from `configure:`.
    @ObservationIgnored private var browserModel: BrowserWidgetModel?
    /// Tab id per tab key, stable for the widget's lifetime so tabs keep their page and selection.
    @ObservationIgnored private var tabIDs: [String: UUID] = [:]
    /// The title last pushed to each tab, so a page's own title isn't overwritten by every sync.
    @ObservationIgnored private var titles: [String: String] = [:]
    @ObservationIgnored private var lastListedIds: [String] = []

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
        closeSelection()
        services = nil
        browserModel = nil
        tabIDs = [:]
        titles = [:]
        lastListedIds = []
        hidden = []
        temporary = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(FirebaseConsoleView(widget: self))
    }

    // MARK: Tabs

    /// The tabs to show right now.
    var descriptors: [FirebaseTabDescriptor] {
        FirebaseTabs.descriptors(for: product, listed: store.projects, hidden: hidden, temporary: temporary)
    }

    /// Called when the shared list may have changed (store change, appearance).
    func storeChanged() {
        let ids = store.projects.map(\.projectId)
        hidden = FirebaseTabs.hiddenAfterListChange(hidden: hidden, previousIds: lastListedIds, currentIds: ids)
        lastListedIds = ids
        syncTabs()
    }

    /// Called from the surface's `configure:` (first mount, or a remount with a cached model).
    func surfaceMounted(_ model: BrowserWidgetModel) {
        browserModel = model
        // A new surface seeds one tab for its first URL. Adopt it as the first tab so that page isn't loaded twice.
        if model.tabs.count == 1, let seeded = model.tabs.first, let first = descriptors.first,
           tabIDs[first.key] == nil, seeded.url == first.url {
            tabIDs[first.key] = seeded.id
        }
        model.onNewTab = { [weak self] in self?.openSelection() }
        model.onTabClosed = { [weak self] id in self?.tabClosed(id) }
        syncTabs()
    }

    /// Makes the browser's tabs match `descriptors`. Tabs are only replaced when the set of tab ids changes,
    /// and existing tabs are kept as they are, so the page and address the user is on survive a sync.
    private func syncTabs() {
        guard let model = browserModel else { return }
        let wanted = descriptors
        guard !wanted.isEmpty else { return }   // the surface is replaced by a message; it re-syncs when mounted again
        let ids = wanted.map { tabID(for: $0.key) }
        if model.tabs.map(\.id) != ids {
            let tabs = zip(wanted, ids).map { descriptor, id in
                model.tabs.first { $0.id == id }
                    ?? BrowserTab(id: id, url: descriptor.url, title: descriptor.title, icon: product.icon)
            }
            model.replaceTabs(tabs)
        }
        for (descriptor, id) in zip(wanted, ids) where titles[descriptor.key] != descriptor.title {
            titles[descriptor.key] = descriptor.title
            model.updateTab(id, title: descriptor.title)
        }
    }

    private func tabID(for key: String) -> UUID {
        if let existing = tabIDs[key] { return existing }
        let created = UUID()
        tabIDs[key] = created
        return created
    }

    /// × on a tab. The browser has already removed it; remember to keep it hidden.
    private func tabClosed(_ tabId: UUID) {
        guard let key = tabIDs.first(where: { $0.value == tabId })?.key else { return }
        if key.hasPrefix(FirebaseTabs.temporaryPrefix) {
            temporary = nil
            tabIDs[key] = nil
            titles[key] = nil
        } else {
            hidden.insert(key)
        }
    }

    // MARK: Project selection window

    func openSelection() {
        guard selectionModel == nil, let services else { return }
        let shell = services.shell
        selectionModel = FirebaseProjectPickerModel(
            run: { command in
                let result = try await shell.run(command: command)
                return FirebaseShellResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
            },
            store: store)
    }

    func closeSelection() {
        selectionModel?.cancel()   // a no-op once saved
        selectionModel = nil
    }
}

// MARK: - View

@MainActor
private struct FirebaseConsoleView: View {
    let widget: FirebaseConsoleWidget

    var body: some View {
        content
            .overlay(alignment: .bottomTrailing) {
                FirebaseProjectsPill { widget.openSelection() }
                    .padding(12)
            }
            .sheet(isPresented: Binding(get: { widget.selectionModel != nil }, set: { if !$0 { widget.closeSelection() } })) {
                if let model = widget.selectionModel {
                    FirebaseProjectSelectionSheet(model: model) { widget.closeSelection() }
                }
            }
            .onChange(of: widget.store.state) { _, _ in widget.storeChanged() }
            .onAppear {
                widget.store.reload()
                widget.storeChanged()
            }
    }

    @ViewBuilder
    private var content: some View {
        if case .invalid(let why) = widget.store.state {
            message(why)
        } else if let first = widget.descriptors.first {
            BrowserSurface(
                spec: BrowserSurfaceSpec(url: first.url, selector: "", dataStoreKey: "browser",
                                         title: widget.product.title, icon: widget.product.icon),
                cacheKey: widget.id,
                configure: { [weak widget] model in widget?.surfaceMounted(model) })
        } else {
            message(FirebaseTabs.emptyMessage(listedCount: widget.store.projects.count))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The small floating button that opens the project selection: the Firebase flame and "Projects" on
/// untinted Liquid Glass (`glassCapsuleSurface`, with a material fallback before macOS 26).
private struct FirebaseProjectsPill: View {
    let action: () -> Void

    private static let mark = NSImage(data: FirebaseBrand.firebaseMarkPNG)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let mark = Self.mark {
                    Image(nsImage: mark)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text("Projects")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassCapsuleSurface()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open Projects Selection")
    }
}
