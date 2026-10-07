// Linear42Links.swift — which Linear URLs each linear42 widget owns.
//
// A link clicked inside any browser widget (Issue Details, a Spec Document, the GitHub PR page…) is offered
// to the widget whose pattern matches it. That widget's tab is focused and it shows the URL itself, so the
// click never navigates the page it was clicked in. Patterns are ICU regexes (the dialect Open Link
// resolves with); a leading `(?i)` is translated for the in-page interceptor. Linear workspaces are
// matched generically: a link to another workspace is still a Linear page of that kind.
//
// Verbatim copies live in linear-issue, linear-spec and linear-testing (run.sh fails on drift).

import Foundation

/// `https://linear.app/<workspace>/issue/<KEY>[/slug][?…][#…]`
let linearIssueLinkPattern = #"(?i)^https?://linear\.app/[^/?#]+/issue/[a-z][a-z0-9]*-[0-9]+(?:[/?#].*)?$"#

/// `https://linear.app/<workspace>/document/[<title slug>-]spec-<12 hex>` — a document titled "<KEY> Spec"
/// (or the older plain "Spec"). Owned by NAME, not by the ids stored in a session, so Spec Document owns
/// these links whether or not its tab is open; one it doesn't hold yet opens in a temporary tab.
let linearSpecDocLinkPattern = #"(?i)^https?://linear\.app/[^/?#]+/document/(?:[^/?#]*-)?spec-[0-9a-f]{12}(?:[/?#].*)?$"#

/// `https://linear.app/<workspace>/document/[<title slug>-]testing-plan-<12 hex>` — "<KEY> Testing Plan"
/// (or the older "Testing plan").
let linearTestingDocLinkPattern = #"(?i)^https?://linear\.app/[^/?#]+/document/(?:[^/?#]*-)?testing-plan-[0-9a-f]{12}(?:[/?#].*)?$"#

/// The unique slug id Linear appends to a document URL (`.../document/wor-6-spec-2838a00c306b` ->
/// `2838a00c306b`): the 12 hex characters after the last `-` of the last path component. Nil for
/// anything else (an issue URL, a document without one).
func documentSlugID(from url: URL) -> String? {
    guard let last = url.pathComponents.last, url.pathComponents.contains("document"),
          let dash = last.lastIndex(of: "-")
    else { return nil }
    let id = last[last.index(after: dash)...]
    guard id.count == 12, id.allSatisfy(\.isHexDigit) else { return nil }
    return String(id).lowercased()
}

/// One tab of Spec Document / Testing Plan Document.
struct DocumentTab: Equatable {
    /// The issue the document belongs to; nil for an older single-issue session's flat `linear/spec_doc`.
    var key: String?
    var url: URL
    var slugID: String
    /// False for a document opened through a link that no attached issue holds (a temporary tab).
    var stored: Bool
}

/// The tabs to show: every stored document in issue order, then temporary ones, each document once
/// (identified by its slug id, else its URL).
func documentTabs(stored: [(key: String?, url: URL)], temporary: [URL]) -> [DocumentTab] {
    var seen = Set<String>()
    func id(_ url: URL) -> String { documentSlugID(from: url) ?? url.absoluteString }
    var tabs: [DocumentTab] = []
    for item in stored where seen.insert(id(item.url)).inserted {
        tabs.append(DocumentTab(key: item.key, url: item.url, slugID: id(item.url), stored: true))
    }
    for url in temporary where seen.insert(id(url)).inserted {
        tabs.append(DocumentTab(key: nil, url: url, slugID: id(url), stored: false))
    }
    return tabs
}

/// "📐 WOR-6 Spec", or "📐 Spec" when the document has no issue key.
func documentTabTitle(emoji: String, kind: String, key: String?) -> String {
    key.map { "\(emoji) \($0) \(kind)" } ?? "\(emoji) \(kind)"
}

/// The destination a widget shows after claiming a link: nil when it is the page the widget already
/// shows (focusing the tab is all that's needed), so the page isn't reloaded.
func linkDestination(_ url: URL, current: URL?) -> URL? {
    guard let current else { return url }
    return current.absoluteString == url.absoluteString ? nil : url
}
