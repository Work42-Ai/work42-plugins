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

/// `https://linear.app/<workspace>/document/spec-<12 hex>` — the document the Planner titles "Spec".
let linearSpecDocLinkPattern = #"(?i)^https?://linear\.app/[^/?#]+/document/spec-[0-9a-f]{12}(?:[/?#].*)?$"#

/// `https://linear.app/<workspace>/document/testing-plan-<12 hex>` — the "Testing plan" document.
let linearTestingDocLinkPattern = #"(?i)^https?://linear\.app/[^/?#]+/document/testing-plan-[0-9a-f]{12}(?:[/?#].*)?$"#

/// The destination a widget shows after claiming a link: nil when it is the page the widget already
/// shows (focusing the tab is all that's needed), so the page isn't reloaded.
func linkDestination(_ url: URL, current: URL?) -> URL? {
    guard let current else { return url }
    return current.absoluteString == url.absoluteString ? nil : url
}
