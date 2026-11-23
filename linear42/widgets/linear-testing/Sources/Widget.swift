// Widget.swift — linear42's Testing Plan widget.
//
// Renders the testing plans as the Linear Documents the Planner attached to the session's issues
// (`linear/issues/<KEY>/testing_doc`), one tab per document, in a BrowserSurface on the user's linear.app
// login. Read-only: the Planner authors the documents with `publish-doc.py`.
//
// STORAGE (storageNamespace "linear"):
//   linear/issue_keys                 — the attached issue keys.
//   linear/issues/<KEY>/testing_doc   — {slug,url}. Written by the Planner after `publish-doc.py`.

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
final class LinearTestingWidget: Work42Widget, Work42BrowserBacked {

    let id = "linear-testing"
    let title = "Testing Plan Document"
    let icon = "testtube.2"
    /// The Linear logo in the + Widget menu, the tab and the header; the symbol above is the fallback.
    var iconImageData: Data? { linearIconPNG }
    var storageNamespace: String? { "linear" }
    /// Links to testing plan documents open here (the tab is focused and the document selected) instead of
    /// navigating the page they were clicked in.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [.regex(linearTestingDocLinkPattern)],
                perform: { [weak self] url in self?.openLink(url) }
            ),
        ]
    }

    /// Documents the attached issues hold (`linear/issues/<KEY>/testing_doc`; an older single-issue session's flat
    /// `linear/testing_doc` has no key), in issue order.
    var docs: [(key: String?, url: URL)] = []
    /// Documents opened through a link that no attached issue holds.
    var temporary: [URL] = []
    @ObservationIgnored private var browserTask: Task<Void, Never>?
    /// The last `setTabs` / `selectTab` call, so the next one starts after it and the tabs end as the last call said.
    @ObservationIgnored private var pendingTabsCall: Task<Void, Never>?
    @ObservationIgnored private var tabIDs: [String: UUID] = [:]

    /// One tab per stored document, then the temporary ones.
    var tabs: [DocumentTab] { documentTabs(stored: docs, temporary: temporary) }

    func stableTabID(for slugID: String) -> UUID {
        if let existing = tabIDs[slugID] { return existing }
        let new = UUID()
        tabIDs[slugID] = new
        return new
    }

    /// Shows one tab per document, through services.browser. The first call also builds the browser from `browserSurface` when no
    /// view has. A no-op while there is no document to show.
    func syncTabs() {
        let shown = tabs.map { tab in
            BrowserTab(id: stableTabID(for: tab.slugID), url: tab.url,
                       title: documentTabTitle(emoji: "🧪", kind: "Testing Plan", key: tab.key),
                       icon: "testtube.2")
        }
        enqueue { try await $0.setTabs(shown) }
    }

    private func selectTab(_ id: UUID) {
        enqueue { try await $0.selectTab(id) }
    }

    /// Runs `call` on this widget's browser after the previous one finished. A failure (no browser yet) changes nothing.
    private func enqueue(_ call: @escaping @MainActor (any BrowserTabsService) async throws -> Void) {
        guard let browser = services?.browser else { return }
        let previous = pendingTabsCall
        pendingTabsCall = Task { @MainActor in
            await previous?.value
            try? await call(browser)
        }
    }

    /// Open Link handed this widget a document URL: select its tab, or open it in a temporary one.
    func openLink(_ url: URL) {
        if !tabs.contains(where: { $0.url == url }) { temporary.append(url) }
        syncTabs()
        let slugID = documentSlugID(from: url) ?? url.absoluteString
        selectTab(stableTabID(for: slugID))
    }

    /// A tab was closed: a temporary one goes; a stored document's tab comes back (its issue still holds it).
    func tabClosed(_ tabID: UUID) {
        if let slugID = tabIDs.first(where: { $0.value == tabID })?.key,
           let tab = tabs.first(where: { $0.slugID == slugID }), !tab.stored {
            temporary.removeAll { (documentSlugID(from: $0) ?? $0.absoluteString) == slugID }
            tabIDs.removeValue(forKey: slugID)
        }
        syncTabs()
    }

    /// Reads the stored documents; assigns only on change so the view never re-renders for an unchanged poll.
    func refreshDocs(_ services: SessionServices) async {
        func read(_ key: String) async -> WidgetJSONValue? {
            (try? await services.storage.get(namespace: "linear", key: key)) ?? nil
        }
        var keys: [String] = []
        if case .array(let items)? = await read("issue_keys") {
            keys = items.compactMap { item in
                if case .string(let s) = item { return s }
                return nil
            }
        }
        var found: [(key: String?, url: URL)] = []
        for key in keys {
            if let doc = LinearDocRef(await read("issues/\(key)/testing_doc")) { found.append((key: key, url: doc.url)) }
        }
        if keys.isEmpty, let doc = LinearDocRef(await read("testing_doc")) { found.append((key: nil, url: doc.url)) }
        let changed = found.map(\.url) != docs.map(\.url) || found.map { $0.key ?? "" } != docs.map { $0.key ?? "" }
        guard changed else { return }
        docs = found
        temporary.removeAll { url in found.contains { $0.url == url } }
        syncTabs()
    }

    private var services: SessionServices?

    func activate(services: SessionServices) {
        self.services = services
        observeBrowser(services.browser)
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    func deactivate() {
        services = nil
        browserTask?.cancel()
        browserTask = nil
        pendingTabsCall?.cancel()
        pendingTabsCall = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    /// Hears the tab bar through services.browser. Documents come from the issues' storage, so "+" has nothing to add; "×"
    /// brings a stored document's tab back.
    private func observeBrowser(_ browser: any BrowserTabsService) {
        browserTask?.cancel()
        browserTask = Task { @MainActor [weak self] in
            for await event in browser.events {
                switch event {
                case .newTabRequested: break
                case .tabClosed(let tabID): self?.tabClosed(tabID)
                @unknown default: break
                }
            }
        }
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(LinearTestingView(widget: self))
    }

    /// The testing plan documents as a browser, or nil while the issues hold none. The view and the host's headless resolve are
    /// both made from this, so a device that opens the tab the Mac never showed gets the same tabs.
    var browserSurface: BrowserSurfaceDeclaration? {
        guard let first = tabs.first else { return nil }
        return BrowserSurfaceDeclaration(
            spec: BrowserSurfaceSpec(
                url: first.url,
                selector: "",
                dataStoreKey: "browser",
                title: "Testing Plan Document",
                icon: "testtube.2"
            ),
            cacheKey: id
        )
    }

    func refresh() async {
        guard let services else { return }
        await refreshDocs(services)
    }
}

@MainActor
private struct LinearTestingView: View {
    let widget: LinearTestingWidget

    var body: some View {
        Group {
            if let declaration = widget.browserSurface {
                BrowserSurface(declaration)
                .task { widget.syncTabs() }
                .onChange(of: widget.tabs.map(\.slugID)) { _, _ in widget.syncTabs() }
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
public func work42_widget_sdk_version() -> Int32 { Work42SDKCompatibility.versionProbeValue }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(LinearTestingWidget())
    }
    return result
}
