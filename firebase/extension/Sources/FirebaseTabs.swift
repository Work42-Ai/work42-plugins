// FirebaseTabs.swift — which browser tabs a Firebase widget shows.
//
// A pure function of (product, shared project list, tabs this widget hid, temporary link tab), so the
// rules are tested without the Work42 SDK. The widget turns the result into BrowserSurface tabs.
// Foundation only.

import Foundation

/// One tab a widget should show.
struct FirebaseTabDescriptor: Equatable, Sendable {
    /// Stable identity: the project ID for a listed project, `temp:<projectId>` for a temporary tab.
    var key: String
    var title: String
    var url: URL
    /// Opened from a link for a project that isn't in the shared list; never saved.
    var isTemporary: Bool
}

/// A link tab for a project that isn't in the shared list. Lives only in the widget that opened it.
struct FirebaseTemporaryTab: Equatable, Sendable {
    var projectId: String
    var url: URL
}

/// What opening a Console link means for one widget.
enum FirebaseLinkAction: Equatable, Sendable {
    /// The project is listed: unhide and select its tab, showing this exact URL.
    case selectListed(projectId: String, url: URL)
    /// The project isn't listed: show a temporary tab (never saved).
    case openTemporary(FirebaseTemporaryTab)
    /// Not a Console link for this widget's product.
    case ignore
}

enum FirebaseTabs {
    static let temporaryPrefix = "temp:"

    /// Decides what a widget for `product` does with a clicked Console `url`.
    static func linkAction(for url: URL, product: FirebaseProduct, listed: [FirebaseProjectEntry]) -> FirebaseLinkAction {
        guard let target = FirebaseProduct.parse(url), target.segment == product.linkSegment else { return .ignore }
        if listed.contains(where: { $0.projectId == target.projectId }) {
            return .selectListed(projectId: target.projectId, url: url)
        }
        return .openTemporary(FirebaseTemporaryTab(projectId: target.projectId, url: url))
    }

    static func temporaryKey(_ projectId: String) -> String { temporaryPrefix + projectId }

    /// Listed projects not hidden in this widget, in list order, then the temporary tab (omitted when its
    /// project has since been listed). Each listed project opens on `product`'s Console page.
    /// `overrides` replaces a listed project's page with an exact URL (a link that was just opened).
    static func descriptors(for product: FirebaseProduct, listed: [FirebaseProjectEntry], hidden: Set<String>,
                            temporary: FirebaseTemporaryTab?, overrides: [String: URL] = [:]) -> [FirebaseTabDescriptor] {
        var tabs: [FirebaseTabDescriptor] = listed.compactMap { entry in
            guard !hidden.contains(entry.projectId),
                  let url = overrides[entry.projectId] ?? product.consoleURL(projectId: entry.projectId) else { return nil }
            return FirebaseTabDescriptor(key: entry.projectId, title: entry.displayName, url: url, isTemporary: false)
        }
        if let temporary, !listed.contains(where: { $0.projectId == temporary.projectId }) {
            tabs.append(FirebaseTabDescriptor(key: temporaryKey(temporary.projectId), title: "\(temporary.projectId) (link)",
                                              url: temporary.url, isTemporary: true))
        }
        return tabs
    }

    /// Hidden tabs come back whenever the shared list of project IDs changes (added, removed or reordered).
    static func hiddenAfterListChange(hidden: Set<String>, previousIds: [String], currentIds: [String]) -> Set<String> {
        previousIds == currentIds ? hidden : []
    }

    /// What an empty widget says. `listedCount` is the size of the shared list.
    static func emptyMessage(listedCount: Int) -> String {
        listedCount > 0
            ? "All projects are hidden in this widget. They come back when the project list changes."
            : "No Firebase projects yet. Use Projects to choose which ones every Firebase widget shows."
    }
}
