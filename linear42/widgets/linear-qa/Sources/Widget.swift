// Widget.swift — linear42's QA Report widget.
//
// Renders the QA reports as the Linear Documents QA published for the session's issues (`qa/docs`), one tab
// per document, in a BrowserSurface on the user's linear.app login. Read-only: QA authors the documents with
// `publish-doc.py --kind qa` and records them.
//
// STORAGE (read only):
//   linear/issue_keys   — the attached issue keys (tab order).
//   qa/docs             — {"<KEY>": {slug,url}}. Written by QA after `publish-doc.py --kind qa`.

import Foundation
import Observation
import SwiftUI
import Work42PluginKit

/// A Linear document reference: `{slug,url}`.
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
final class LinearQAWidget: Work42Widget {

    let id = "linear-qa"
    let title = "QA Report Document"
    let icon = "checkmark.seal"
    /// The Linear logo in the + Widget menu, the tab and the header; the symbol above is the fallback.
    var iconImageData: Data? { linearIconPNG }
    var storageNamespace: String? { "linear" }
    /// Links to QA report documents open here (the tab is focused and the document selected) instead of
    /// navigating the page they were clicked in.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [.regex(linearQADocLinkPattern)],
                perform: { [weak self] url in self?.openLink(url) }
            ),
        ]
    }

    /// The QA report documents (`qa/docs`), in issue order.
    var docs: [(key: String?, url: URL)] = []
    /// Documents opened through a link that no attached issue holds.
    var temporary: [URL] = []
    @ObservationIgnored var browserModel: BrowserWidgetModel?
    @ObservationIgnored private var tabIDs: [String: UUID] = [:]

    /// One tab per stored document, then the temporary ones.
    var tabs: [DocumentTab] { documentTabs(stored: docs, temporary: temporary) }

    func stableTabID(for slugID: String) -> UUID {
        if let existing = tabIDs[slugID] { return existing }
        let new = UUID()
        tabIDs[slugID] = new
        return new
    }

    func syncTabs() {
        guard let model = browserModel else { return }
        model.replaceTabs(tabs.map { tab in
            BrowserTab(id: stableTabID(for: tab.slugID), url: tab.url,
                       title: documentTabTitle(emoji: "🧾", kind: "QA Report", key: tab.key),
                       icon: "checkmark.seal")
        })
    }

    /// Open Link handed this widget a document URL: select its tab, or open it in a temporary one.
    func openLink(_ url: URL) {
        if !tabs.contains(where: { $0.url == url }) { temporary.append(url) }
        syncTabs()
        let slugID = documentSlugID(from: url) ?? url.absoluteString
        browserModel?.selectTab(stableTabID(for: slugID))
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
        func read(_ namespace: String, _ key: String) async -> WidgetJSONValue? {
            (try? await services.storage.get(namespace: namespace, key: key)) ?? nil
        }
        var keys: [String] = []
        if case .array(let items)? = await read("linear", "issue_keys") {
            keys = items.compactMap { item in
                if case .string(let s) = item { return s }
                return nil
            }
        }
        var entries: [String: WidgetJSONValue] = [:]
        if case .object(let o)? = await read("qa", "docs") { entries = o }
        let ordered = keys.filter { entries[$0] != nil } + entries.keys.filter { !keys.contains($0) }.sorted()
        var found: [(key: String?, url: URL)] = []
        for key in ordered {
            if let doc = LinearDocRef(entries[key]) { found.append((key: key, url: doc.url)) }
        }
        let changed = found.map(\.url) != docs.map(\.url) || found.map { $0.key ?? "" } != docs.map { $0.key ?? "" }
        guard changed else { return }
        docs = found
        temporary.removeAll { url in found.contains { $0.url == url } }
        syncTabs()
    }

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
        AnyView(LinearQAView(widget: self))
    }

    func refresh() async {
        guard let services else { return }
        await refreshDocs(services)
    }
}

@MainActor
private struct LinearQAView: View {
    let widget: LinearQAWidget

    var body: some View {
        Group {
            if let first = widget.tabs.first {
                BrowserSurface(
                    spec: BrowserSurfaceSpec(
                        url: first.url,
                        selector: "",
                        dataStoreKey: "browser",
                        title: "QA Report Document",
                        icon: "checkmark.seal"
                    ),
                    cacheKey: widget.id,
                    configure: { [weak widget] model in
                        guard let widget else { return }
                        widget.browserModel = model
                        widget.syncTabs()
                        // Documents come from `qa/docs`, so + has nothing to add.
                        model.onNewTab = {}
                        model.onTabClosed = { [weak widget] tabID in widget?.tabClosed(tabID) }
                    }
                )
                .onChange(of: widget.tabs.map(\.slugID)) { _, _ in widget.syncTabs() }
            } else {
                VStack(alignment: .leading, spacing: DT.s8) {
                    LinearBrandMark(size: 28)
                    Text("No QA report yet")
                        .font(.system(size: DT.f13, weight: .semibold))
                    Text("QA publishes the report as a Linear document on the issue when it finishes testing. It appears here automatically.")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DT.s12)
                .padding(.top, DT.s12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // Live refresh while on screen: `qa/docs` lands without reopening the tab.
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
        result = WidgetEntryPoint.register(LinearQAWidget())
    }
    return result
}
