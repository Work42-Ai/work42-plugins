import Foundation

enum GitHubWidgetLinkSupport {
    static let webURLPattern =
        #"(?i)^https?://github\.com(?:[/?#].*)?$"#

    /// The pull request a github.com URL points into, any sub-route or anchor of it
    /// (`/pull/42`, `/pull/42/files#diff-1`, `/pull/42/commits/abc`), as `owner/repo#number`. Owner and
    /// repository compare case-insensitively. Nil for anything that is not a pull-request page.
    static func pullRequestKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com"
        else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, parts[2].lowercased() == "pull", let number = Int(parts[3]) else { return nil }
        return "\(parts[0].lowercased())/\(parts[1].lowercased())#\(number)"
    }

    /// Whether `url` is inside the pull request that `page` is showing. A link like that navigates within the
    /// current tab; a different PR, a repository or an issue page opens a tab of its own.
    static func isSamePullRequest(_ url: URL, as page: URL) -> Bool {
        guard let key = pullRequestKey(url), let pageKey = pullRequestKey(page) else { return false }
        return key == pageKey
    }

    /// Compose task-attached PRs with one transient Open Link destination.
    /// The input array is never mutated and an already-attached URL is not
    /// duplicated.
    static func displayedURLs(attached: [URL], opened: URL?) -> [URL] {
        guard let opened,
              !attached.contains(where: { $0.absoluteString == opened.absoluteString })
        else { return attached }
        return attached + [opened]
    }
}
