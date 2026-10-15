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

    static let auth = FirebaseProduct(
        id: "auth", widgetId: "firebase-auth", title: "Firebase Authentication",
        icon: "person.badge.key", consolePath: "authentication/users")
    static let analytics = FirebaseProduct(
        id: "analytics", widgetId: "firebase-analytics", title: "Firebase Analytics",
        icon: "chart.bar", consolePath: "analytics/overview")
    static let firestore = FirebaseProduct(
        id: "firestore", widgetId: "firebase-firestore", title: "Firebase Firestore",
        icon: "cylinder.split.1x2", consolePath: "firestore")
    static let crashlytics = FirebaseProduct(
        id: "crashlytics", widgetId: "firebase-crashlytics", title: "Firebase Crashlytics",
        icon: "exclamationmark.triangle", consolePath: "crashlytics")

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

    /// RFC 3986 unreserved characters only.
    private static let pathComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
