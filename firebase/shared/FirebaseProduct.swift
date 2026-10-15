// FirebaseProduct.swift — the four Firebase products this plugin ships, and where each lives in the Console.
//
// One catalog, shared by every widget. A widget turns (product, project ID) into a Console URL here and
// nowhere else. Foundation only, so the logic tests compile it without the Work42 SDK.

import Foundation

struct FirebaseProduct: Equatable, Sendable {
    /// Stable short ID (also the suffix of the widget ID and the skill name).
    let id: String
    /// The widget's `id` / catalog slug.
    let widgetId: String
    /// The title shown in the `+ Widget` menu, the widget chrome and the browser chrome.
    let title: String
    /// SF Symbol for the menu row.
    let icon: String
    /// Path under `/project/<projectId>/` of this product's Console page.
    let consolePath: String
    /// The product's official Firebase icon, a 64x64 PNG with alpha (see `FirebaseBrand`).
    let iconPNG: Data

    static let auth = FirebaseProduct(
        id: "auth", widgetId: "firebase-auth", title: "Firebase Authentication",
        icon: "person.badge.key", consolePath: "authentication/users",
        iconPNG: FirebaseBrand.authIconPNG)
    static let analytics = FirebaseProduct(
        id: "analytics", widgetId: "firebase-analytics", title: "Firebase Analytics",
        icon: "chart.bar", consolePath: "analytics/overview",
        iconPNG: FirebaseBrand.analyticsIconPNG)
    static let firestore = FirebaseProduct(
        id: "firestore", widgetId: "firebase-firestore", title: "Firebase Firestore",
        icon: "cylinder.split.1x2", consolePath: "firestore",
        iconPNG: FirebaseBrand.firestoreIconPNG)
    static let crashlytics = FirebaseProduct(
        id: "crashlytics", widgetId: "firebase-crashlytics", title: "Firebase Crashlytics",
        icon: "exclamationmark.triangle", consolePath: "crashlytics",
        iconPNG: FirebaseBrand.crashlyticsIconPNG)

    static let all: [FirebaseProduct] = [.auth, .analytics, .firestore, .crashlytics]

    static let consoleHost = "console.firebase.google.com"

    /// `https://console.firebase.google.com/project/<projectId>/<consolePath>`. The project ID is
    /// percent-encoded as a single path component, so a stray `/`, `?` or `#` in a hand-edited config can't
    /// change which page opens. nil for a blank project ID.
    func consoleURL(projectId: String) -> URL? {
        let trimmed = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.consoleHost
        components.percentEncodedPath = "/project/\(encoded)/\(consolePath)"
        return components.url
    }

    /// Where to send the browser when the shared selection is `selected` and the page currently shows
    /// `loaded` (nil = nothing loaded yet). nil means "leave the page alone": no selection, or the project
    /// hasn't changed, so ordinary Console browsing is never reset by a repeated config read.
    func navigationTarget(selected: String?, loaded: String?) -> URL? {
        guard let selected, selected != loaded else { return nil }
        return consoleURL(projectId: selected)
    }

    // MARK: Console links

    /// The first path segment of this product's Console pages (`authentication`, `analytics`, `firestore`,
    /// `crashlytics`): what a Console link must have after the project ID to belong to this widget.
    var linkSegment: String {
        consolePath.split(separator: "/").first.map(String.init) ?? consolePath
    }

    /// Matches the canonical Console URLs of this product, for the host's Open Link routing:
    /// `https://console.firebase.google.com/[u/<n>/]project/<projectId>/<segment>[/…|?…|#…]`.
    var linkPattern: String {
        #"^https://console\.firebase\.google\.com/(u/[0-9]+/)?project/[^/?#]+/"# + linkSegment + #"(/|\?|#|$)"#
    }

    /// The project ID and product segment of a Firebase Console project URL, or nil for any other URL.
    static func parse(_ url: URL) -> (projectId: String, segment: String)? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == consoleHost,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 2, parts[0] == "u", Int(parts[1]) != nil { parts.removeFirst(2) }
        guard parts.count >= 3, parts[0] == "project",
              let projectId = parts[1].removingPercentEncoding, !projectId.isEmpty else { return nil }
        return (projectId, parts[2])
    }

    /// True when both URLs are Console pages of the same project and product, so a link clicked inside the
    /// page can navigate in place instead of opening another tab.
    static func isSamePage(_ url: URL, _ pageURL: URL) -> Bool {
        guard let a = parse(url), let b = parse(pageURL) else { return false }
        return a.projectId == b.projectId && a.segment == b.segment
    }

    /// RFC 3986 unreserved characters only.
    private static let pathComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
