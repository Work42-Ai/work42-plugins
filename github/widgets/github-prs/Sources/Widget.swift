// Widget.swift — github-prs widget (feat/plugings-implementation.17)
//
// REWORK: Replaces the old gh-list approach entirely.
//
// DESIGN (settled with Yan):
//   A HOME-surface browser widget that renders ONE TAB PER WORKSPACE REPOSITORY
//   plus any manually stored repositories, at each repo's GitHub PRs page
//   (https://github.com/<owner>/<repo>/pulls).
//
// REPO ENUMERATION (shell, no gh CLI required):
//   On Home, services.shell cwd = the multi-repo workspace root. The widget:
//   1. Checks if the root itself is a git repo (.git present). If so, yields it.
//   2. Otherwise enumerates depth-1 subdirs that are git repos.
//   For each: `git -C <dir> config --get remote.origin.url` → parse owner/repo.
//
// TABS:
//   One BrowserSurface tab per workspace repo at its /pulls page. Uses
//   model.replaceTabs (via the configure closure, which saves the model in `browserModel`).
//
// ACTION-AREA INTENT:
//   "Review GitHub PR" — placement: [.palette, .actionArea].
//   isEnabled closure returns true ONLY when the active tab's URL (model.urlDraft)
//   matches a PR page (/pull/<N> path). Enabled = the button appears in the
//   action center, resolves the PR head branch with `gh`, and fires the generic
//   session.open intent (typeId "codeReview") with branch + initial github/prs
//   metadata.
//
// FAIL LOUD:
//   If no GitHub repos are found or the shell fails, renders a fail-loud error
//   card with a retry button — never a blank tile.
//
// SESSION METADATA: Seeds github/prs in the new session so the separate
// `github` session widget can render and monitor the selected pull request.
// Uses `git` for repository discovery and authenticated `gh` only when the
// user asks to open the currently viewed PR as a Code Review session.
//
// WIDGET ID: "github-prs" (unchanged — the loader keyed this slug).

import AppKit
import Foundation
import Observation
import SwiftUI
import Work42PluginKit

// MARK: - RepoInfo

/// One workspace git repository resolved to its GitHub PRs page URL.
struct RepoInfo: Sendable, Equatable {
    /// RepoDiscovery-compatible workspace key ("." for a root repo). Nil for
    /// manually added repositories that have no local checkout.
    var repoKey: String?
    /// "owner/repo" — used as the browser tab title.
    var ownerRepo: String
    /// https://github.com/<owner>/<repo>/pulls
    var url: URL
    /// Stable UUID for the BrowserSurface tab (survives replaceTabs idempotently).
    var tabID: UUID
}

// MARK: - Load state

enum GitHubPRsLoadState: Sendable {
    case loading
    /// Non-empty repos → BrowserSurface; empty is handled by caller (treated as error).
    case ready([RepoInfo])
    case error(String)
}

// MARK: - GitHub remote URL parsing
//
// Mirrors Work42Core.GitRemote — inlined here because widget dylibs link only
// Work42UI + Work42PluginKit. Any format changes there should be kept in sync.

/// Parse a git remote URL into (owner, repo). Returns nil for non-GitHub URLs.
///
/// Recognised forms:
///   git@github.com:owner/repo.git          SSH shorthand
///   https://github.com/owner/repo(.git)    HTTPS
///   ssh://git@github.com/owner/repo.git    SSH explicit
private func parseGitHubOwnerRepo(_ remoteURL: String) -> (owner: String, repo: String)? {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lower = trimmed.lowercased()

    // SSH shorthand: git@github.com:owner/repo.git
    let sshShortPrefix = "git@github.com:"
    if lower.hasPrefix(sshShortPrefix) {
        return splitGitHubOwnerRepo(String(trimmed.dropFirst(sshShortPrefix.count)))
    }
    // HTTPS: https://github.com/owner/repo(.git)
    if lower.hasPrefix("https://github.com/") || lower.hasPrefix("http://github.com/") {
        // Find the slash after the host (skip "https://" = 8 chars)
        let startIdx = trimmed.index(trimmed.startIndex, offsetBy: min(8, trimmed.count))
        if let slashRange = trimmed.range(of: "/", range: startIdx..<trimmed.endIndex) {
            return splitGitHubOwnerRepo(String(trimmed[slashRange.upperBound...]))
        }
    }
    // SSH explicit: ssh://git@github.com/... or ssh://github.com/...
    for prefix in ["ssh://git@github.com/", "ssh://github.com/"] {
        if lower.hasPrefix(prefix) {
            return splitGitHubOwnerRepo(String(trimmed.dropFirst(prefix.count)))
        }
    }
    return nil
}

/// Split `"owner/repo(.git)(/)"` into lower-cased `(owner, repo)`. Returns nil
/// when the path doesn't have at least two non-empty components.
private func splitGitHubOwnerRepo(_ path: String) -> (owner: String, repo: String)? {
    var cleaned = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if cleaned.lowercased().hasSuffix(".git") {
        cleaned = String(cleaned.dropLast(4))
    }
    cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let parts = cleaned.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    let owner = String(parts[0]).lowercased()
    let repo  = String(parts[1]).lowercased()
    guard !owner.isEmpty, !repo.isEmpty else { return nil }
    return (owner, repo)
}

/// Parse user input for the add-repository form. Accepts a GitHub remote/URL or
/// exactly `owner/repo`; rejects URLs for any other host and extra path parts.
private func parseAddedGitHubRepo(_ input: String) -> (owner: String, repo: String)? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let parsed = parseGitHubOwnerRepo(trimmed) { return parsed }
    guard !trimmed.contains("://"), !trimmed.contains("@") else { return nil }
    let parts = trimmed
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    return splitGitHubOwnerRepo(trimmed)
}

/// Return true when `urlString` points to a GitHub PR page (path: /owner/repo/pull/<N>).
private func isGitHubPRPage(_ urlString: String) -> Bool {
    githubPRReference(urlString) != nil
}

private func githubPRReference(_ urlString: String) -> (ownerRepo: String, number: Int)? {
    guard !urlString.isEmpty,
          let url = URL(string: urlString),
          let host = url.host,
          host.lowercased().hasSuffix("github.com")
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    // Expected: ["owner", "repo", "pull", "N", ...]
    guard parts.count >= 4,
          parts[2].lowercased() == "pull",
          let number = Int(parts[3])
    else { return nil }
    return ("\(parts[0].lowercased())/\(parts[1].lowercased())", number)
}

// MARK: - PATH enrichment

/// Prepend common Homebrew / local dirs to PATH for git invocations.
private let enrichedPathPrefix = "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

// MARK: - GitHubPRsWidget

/// Widget id: `github-prs`. Browser widget showing one tab per repo in the
/// current surface's workspace at its GitHub PRs page. Requires `git` in PATH.
///
/// Available on every surface (the `enabledLayouts` allow-list was removed from
/// the SDK in data-driven-session-surfaces s7). Repo enumeration walks
/// `services.shell`'s cwd — the workspace root on Home, the session's own
/// worktree container in a session (the enumeration handles a worktree's
/// file-shaped `.git`, s8).
@Observable
@MainActor
final class GitHubPRsWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "github-prs"
    let title = "GitHub PRs"
    let icon = "arrow.triangle.pull"
    var iconImageData: Data? { GitHubPRsReviewAgent.githubMarkPNG }

    /// This dashboard starts review sessions but is not a link destination.
    let linkIntents: [WidgetLinkIntentSpec] = []

    // MARK: - Observed state (drives the view)

    var loadState: GitHubPRsLoadState = .loading
    var showingAddRepoForm = false

    // MARK: - Intents

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "start-code-review",
                title: "Review GitHub PR",
                icon: "arrow.triangle.pull",
                iconImageData: GitHubPRsReviewAgent.githubMarkPNG,
                keywords: ["review", "code review", "pr", "pull request", "session"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .labeled,
                isEnabled: { [weak self] in
                    guard let self else { return false }
                    let urlString = self.liveBrowserModel()?.urlDraft ?? ""
                    guard let reference = githubPRReference(urlString),
                          case .ready(let repos) = self.loadState
                    else { return false }
                    return repos.contains {
                        $0.ownerRepo.lowercased() == reference.ownerRepo && $0.repoKey != nil
                    }
                },
                perform: { [weak self] in
                    guard let self else { return }
                    let urlString = self.liveBrowserModel()?.urlDraft ?? ""
                    guard let reference = githubPRReference(urlString) else { return }
                    guard let svc = self.services else { return }
                    guard case .ready(let repos) = self.loadState,
                          let repo = repos.first(where: {
                              $0.ownerRepo.lowercased() == reference.ownerRepo
                          }),
                          let repoKey = repo.repoKey
                    else {
                        throw WidgetServiceError(
                            message: "This pull request does not have a local workspace checkout.",
                            suggestion: "Review sessions require an auto-discovered workspace repository."
                        )
                    }
                    // Review the PR by its HEAD BRANCH NAME so the local review
                    // branch tracks `origin/<branch>` — a normal git fetch keeps
                    // it fresh and Pull fast-forwards it (the row shows "behind"
                    // when the PR advances, never a bogus "merge conflicts").
                    // Fork PRs (whose head branch isn't on this origin) fall back
                    // to the stable `refs/pull/<N>/head` ref (checked out detached).
                    var reviewRef = "refs/pull/\(reference.number)/head"
                    var prTitle = "PR #\(reference.number)"
                    if let result = try? await svc.shell.run(command:
                        "\(ghReviewPathPrefix) && gh pr view \(reference.number) "
                        + "--repo \(reference.ownerRepo) --json title,headRefName,isCrossRepository"
                    ), result.exitCode == 0,
                       let data = result.stdout.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let title = (obj["title"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                            prTitle = title
                        }
                        let isFork = (obj["isCrossRepository"] as? Bool) ?? false
                        if !isFork, let head = (obj["headRefName"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty {
                            reviewRef = head
                        }
                    }
                    try await svc.intents.execute(
                        id: "session.open",
                        params: [
                            "typeId": .string("codeReview"),
                            "name": .string("PR Review: \(prTitle)"),
                            "branchesByRepository": .object([
                                repoKey: .string(reviewRef),
                            ]),
                            "initialWidgetStorage": .object([
                                "github": .object([
                                    "prs": .array([
                                        .object([
                                            "url": .string(urlString),
                                            "status": .string("open"),
                                            "merged_at": .null,
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]
                    )
                }
            ),
        ]
    }

    // MARK: - Internal

    private var services: SessionServices?
    private var enumerationTask: Task<Void, Never>?

    /// The surface's model, saved by the view's `configure:` closure; nil until the view has mounted.
    var browserModel: BrowserWidgetModel?

    /// The surface's model: the one `configure:` saved, else the cache entry under this widget's scope. The SDK
    /// keys each surface by `"<session id or home>/<widget id>"`, so the unscoped lookup finds nothing.
    private func liveBrowserModel() -> BrowserWidgetModel? {
        browserModel ?? BrowserSurface.model(forKey: id, scope: services?.sessionId ?? "home")
    }

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        enumerationTask?.cancel()
        loadState = .loading
        enumerationTask = Task { @MainActor [weak self] in
            await self?.enumerateRepos()
        }
    }

    func deactivate() {
        enumerationTask?.cancel()
        enumerationTask = nil
        services = nil
        browserModel = nil
        loadState = .loading
        showingAddRepoForm = false
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(GitHubPRsRootView(widget: self, services: services))
    }

    // MARK: - Repo enumeration

    /// Enumerate immediate git repos in the workspace root via services.shell,
    /// resolve each to a GitHub remote, and update `loadState`.
    ///
    /// Shell output: one line per resolved repo → "<path>|<remote_url>".
    /// Empty stdout → no GitHub repos found → error state.
    func enumerateRepos() async {
        guard let services else { return }
        let manualOwnerRepos = await loadManualOwnerRepos(services: services)

        // Shell script:
        //   If the workspace root is itself a git repo, use it (solo-repo workspace).
        //   Otherwise enumerate depth-1 subdirs that have a .git entry
        //   (multi-repo workspace; RepoDiscovery's depth-1 rule).
        //   For each repo get its origin remote URL and emit "<path>|<url>".
        //   `-e` (not `-d`): a git WORKTREE's `.git` is a FILE, not a
        //   directory (data-driven-session-surfaces s8) — a session's cwd is
        //   always a worktree container, so `-d` silently enumerated zero
        //   repos there. `-e` matches a real clone's directory AND a
        //   worktree's file.
        let cmd = """
            \(enrichedPathPrefix)
            if [ -e ".git" ]; then
              _url=$(git config --get remote.origin.url 2>/dev/null)
              [ -n "$_url" ] && printf '.|%s\\n' "$_url"
            else
              for _d in */; do
                [ -e "${_d}.git" ] || continue
                _url=$(git -C "${_d%/}" config --get remote.origin.url 2>/dev/null)
                [ -n "$_url" ] && printf '%s|%s\\n' "${_d%/}" "$_url"
              done
            fi
            """

        let result: WidgetShellResult
        do {
            result = try await services.shell.run(command: cmd)
        } catch {
            if !manualOwnerRepos.isEmpty {
                publishRepos(merging: [], manualOwnerRepos: manualOwnerRepos)
                return
            }
            loadState = .error(
                "Could not enumerate workspace repositories.\n\n" +
                error.localizedDescription +
                "\n\nEnsure git is installed and in PATH."
            )
            return
        }

        guard result.exitCode == 0 else {
            if !manualOwnerRepos.isEmpty {
                publishRepos(merging: [], manualOwnerRepos: manualOwnerRepos)
                return
            }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty
                ? "Shell exited with code \(result.exitCode)."
                : String(stderr.prefix(300))
            loadState = .error("Repository enumeration failed.\n\n\(detail)")
            return
        }

        // Parse "path|remote_url" lines into RepoInfo values.
        var repos: [RepoInfo] = []
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let remoteURL = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (owner, repo) = parseGitHubOwnerRepo(remoteURL),
                  let prsURL = URL(string: "https://github.com/\(owner)/\(repo)/pulls")
            else { continue }
            repos.append(RepoInfo(
                repoKey: String(parts[0]),
                ownerRepo: "\(owner)/\(repo)",
                url: prsURL,
                tabID: UUID()
            ))
        }

        repos = merge(autoRepos: repos, manualOwnerRepos: manualOwnerRepos)

        if repos.isEmpty {
            let rawOutput = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg: String
            if rawOutput.isEmpty {
                msg = "No git repositories found in the workspace root, " +
                      "or none have a GitHub remote.\n\n" +
                      "Ensure each workspace repo has `remote.origin.url` " +
                      "pointing to a GitHub URL (HTTPS or SSH)."
            } else {
                msg = "Repos were found but none resolved to a GitHub remote.\n\n" +
                      "Ensure each workspace repo has `remote.origin.url` " +
                      "pointing to a GitHub URL."
            }
            loadState = .error(msg)
        } else {
            publishRepos(repos)
        }
    }

    /// Validate and persist one manual repository. Invalid input returns before
    /// touching storage, preserving the prior list exactly.
    func addManualRepo(_ input: String) async -> String? {
        guard let services else { return "The widget is not active." }
        guard let (owner, repo) = parseAddedGitHubRepo(input) else {
            return "Enter owner/repo or a github.com repository URL."
        }

        let normalized = "\(owner)/\(repo)"
        var stored = await loadManualOwnerRepos(services: services)
        if !stored.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            stored.append(normalized)
            do {
                try await services.storage.set(
                    key: "repos",
                    value: .array(stored.map { .string($0) })
                )
            } catch {
                return "Could not save this repository: \(error.localizedDescription)"
            }
        }

        showingAddRepoForm = false
        await enumerateRepos()
        return nil
    }

    private func loadManualOwnerRepos(services: SessionServices) async -> [String] {
        guard let value = try? await services.storage.get(namespace: id, key: "repos"),
              case .array(let values) = value
        else { return [] }

        var seen: Set<String> = []
        return values.compactMap { value in
            guard case .string(let stored) = value,
                  let (owner, repo) = parseAddedGitHubRepo(stored)
            else { return nil }
            let normalized = "\(owner)/\(repo)"
            guard seen.insert(normalized.lowercased()).inserted else { return nil }
            return normalized
        }
    }

    private func merge(autoRepos: [RepoInfo], manualOwnerRepos: [String]) -> [RepoInfo] {
        var merged: [RepoInfo] = []
        var seen: Set<String> = []

        for repo in autoRepos {
            guard seen.insert(repo.ownerRepo.lowercased()).inserted else { continue }
            merged.append(repo)
        }
        for ownerRepo in manualOwnerRepos {
            let key = ownerRepo.lowercased()
            guard seen.insert(key).inserted,
                  let url = URL(string: "https://github.com/\(ownerRepo)/pulls")
            else { continue }
            merged.append(RepoInfo(
                repoKey: nil,
                ownerRepo: ownerRepo,
                url: url,
                tabID: UUID()
            ))
        }
        return merged
    }

    private func publishRepos(_ repos: [RepoInfo]) {
        loadState = .ready(repos)
        if let model = liveBrowserModel() {
            syncTabs(to: model, repos: repos)
        }
    }

    private func publishRepos(merging autoRepos: [RepoInfo], manualOwnerRepos: [String]) {
        publishRepos(merge(autoRepos: autoRepos, manualOwnerRepos: manualOwnerRepos))
    }

    /// Push one BrowserTab per repo into `model` via replaceTabs.
    /// Called from the BrowserSurface configure closure and from post-enumeration
    /// cache-hit sync.
    func syncTabs(to model: BrowserWidgetModel, repos: [RepoInfo]) {
        let tabs = repos.map { repo in
            BrowserTab(
                id: repo.tabID,
                url: repo.url,
                title: repo.ownerRepo,
                icon: "arrow.triangle.pull"
            )
        }
        model.replaceTabs(tabs)
    }
}

// MARK: - GitHubPRsRootView

/// Root view returned by `makeView`. Dispatches to the correct sub-view based
/// on the widget's observable `loadState`.
@MainActor
private struct GitHubPRsRootView: View {
    let widget: GitHubPRsWidget
    let services: SessionServices

    var body: some View {
        Group {
            switch widget.loadState {
            case .loading:
                GitHubPRsLoadingView()

            case .error(let message):
                GitHubPRsErrorView(
                    message: message,
                    onRetry: { Task { await widget.enumerateRepos() } },
                    onAdd: { widget.showingAddRepoForm = true }
                )

            case .ready(let repos):
                if repos.isEmpty {
                    GitHubPRsErrorView(
                        message: "No GitHub repositories found in the workspace.",
                        onRetry: { Task { await widget.enumerateRepos() } },
                        onAdd: { widget.showingAddRepoForm = true }
                    )
                } else {
                    GitHubPRsBrowserView(widget: widget, repos: repos)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { widget.showingAddRepoForm },
            set: { widget.showingAddRepoForm = $0 }
        )) {
            GitHubPRsAddRepoSheet(widget: widget)
        }
    }
}

// MARK: - Loading view

@MainActor
private struct GitHubPRsLoadingView: View {
    var body: some View {
        VStack(spacing: DT.s12) {
            GitHubBrandMark(size: 28)
            ProgressView()
                .controlSize(.regular)
            Text("Scanning workspace repositories…")
                .font(.system(size: DT.f12))
                .foregroundStyle(DT.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DT.s24)
    }
}

// MARK: - Error view

/// Fail-loud error card. Never a blank tile.
@MainActor
private struct GitHubPRsErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: DT.s16) {
            GitHubBrandMark(size: 32)

            Text("GitHub PRs unavailable")
                .font(.system(size: DT.f13, weight: .medium))
                .foregroundStyle(DT.textPrimary)

            Text(message)
                .font(.system(size: DT.f11))
                .foregroundStyle(DT.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: DT.s8) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                Button("Add repository", action: onAdd)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Browser view

/// Renders a BrowserSurface with one tab per workspace repo at its /pulls page.
/// The configure closure populates tabs via model.replaceTabs so BrowserSurface's
/// seeded first-tab is immediately replaced with the full tab set.
@MainActor
private struct GitHubPRsBrowserView: View {
    let widget: GitHubPRsWidget
    let repos: [RepoInfo]

    var body: some View {
        BrowserSurface(
            spec: BrowserSurfaceSpec(
                url: repos[0].url,
                selector: "",
                dataStoreKey: "github",
                title: "GitHub PRs",
                icon: "arrow.triangle.pull"
            ),
            cacheKey: widget.id,
            configure: { [weak widget] model in
                guard let widget else { return }
                widget.browserModel = model
                widget.syncTabs(to: model, repos: repos)
                model.onNewTab = { [weak widget] in
                    widget?.showingAddRepoForm = true
                }
            }
        )
    }
}

// MARK: - Add repository

@MainActor
private struct GitHubPRsAddRepoSheet: View {
    let widget: GitHubPRsWidget

    @State private var draft = ""
    @State private var errorMessage: String? = nil
    @State private var saving = false

    var body: some View {
        VStack(spacing: DT.s16) {
            GitHubBrandMark(size: 28)

            Text("Add GitHub repository")
                .font(.system(size: DT.f14, weight: .semibold))

            Text("Enter owner/repo or paste a github.com repository URL.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)

            TextField("owner/repo", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addRepo)
                .frame(width: 420)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: DT.s8) {
                Button("Cancel") {
                    widget.showingAddRepoForm = false
                }
                Button("Add repository", action: addRepo)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DT.s24)
        .frame(minWidth: 480)
    }

    private func addRepo() {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            if let error = await widget.addManualRepo(draft) {
                errorMessage = error
            } else {
                draft = ""
            }
        }
    }
}

private struct GitHubBrandMark: View {
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        if let data = GitHubPRsReviewAgent.githubMarkPNG,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(DT.textTertiary)
        }
    }
}

// MARK: - Widget ABI entry points
//
// The two @_cdecl symbols the app's dlopen/dlsym loader expects.
// `nonisolated(unsafe)` local is required because MainActor.assumeIsolated
// cannot return an UnsafeMutableRawPointer directly (not Sendable — see
// reference_cdecl_mainactor_assumeisolated_pointer_sendable in MEMORY.md).

// MARK: - Review-queue header label (feat/home-labels .9)

/// PATH prefix so `gh` resolves under the widget's non-login shell (Homebrew /
/// MacPorts locations), mirroring the single GitHub widget's agent.
private let ghReviewPathPrefix =
    "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

/// The GitHub mark as a small embedded PNG, base64-encoded, so header chips and widget icons show it with no
/// network and no bundle resources. Source: GitHub's official Invertocat from the brand kit
/// (https://brand.github.com/GitHub_Logos.zip, SVG/GitHub_Invertocat_Black.svg, the plain file, not the
/// _Clearspace one), shape unchanged, recoloured green #58BC51 with the cat filled black, 64 x 64 with no
/// transparent margin. One image for light and dark. It goes on a NEUTRAL chip: a chip with a brand fill makes
/// the host redraw the mark as a one-colour silhouette (a blank disc).
private let githubMarkPNGBase64 = "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"

/// Background agent for the GitHub PRs board: publishes a single "N to review"
/// header label — the count of OPEN PRs where the authenticated `gh` user is a
/// requested reviewer. Uses the same `services.shell` + `WidgetBackgroundAgent`
/// + `headerLabels` pattern as the single-PR widget's agent. Fail-soft: any `gh`
/// failure (missing / unauthenticated / nonzero exit / unparseable JSON) leaves
/// `headerLabels` empty — no error chip, no crash (AC15/AC16).
@Observable
@MainActor
final class GitHubPRsReviewAgent: WidgetBackgroundAgent {

    /// The board's contributed header labels. Empty until the first successful
    /// poll finds N > 0. @Observable so the host re-renders the strip on change.
    var headerLabels: [WidgetHeaderLabel] = []

    private var watchTask: Task<Void, Never>?

    func start(services: WidgetBackgroundServices) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            // Brief initial delay so the board renders before the first gh spawn.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                await self?.poll(services: services)
                try? await Task.sleep(nanoseconds: 120_000_000_000) // 2 minutes
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        headerLabels = []
    }

    private func poll(services: WidgetBackgroundServices) async {
        // Enumerate THIS workspace's GitHub repos (same rule as the widget's
        // view). Both counts are scoped to these repos — never a global list —
        // so the chips reflect the workspace you're in.
        let repos = await workspaceRepoSlugs(services: services)
        guard !repos.isEmpty else { headerLabels = []; return }
        let repoArgs = repos.map { "--repo \($0)" }.joined(separator: " ")

        // Two independent, workspace-scoped counts:
        //  • "to review" — open, NON-DRAFT PRs that explicitly request my review.
        //  • "in review" — ALL my open PRs (any draft state).
        let toReview = await count(
            services: services,
            query: "gh search prs --review-requested=@me --state=open --draft=false "
                + "--json url --limit 100 \(repoArgs)")
        let inReview = await count(
            services: services,
            query: "gh search prs --author=@me --state=open "
                + "--json url --limit 100 \(repoArgs)")

        // Each chip shows only when its count > 0 ("to review" hides at 0). Both
        // lead with the GitHub mark + brand color and carry NO url, so clicking
        // focuses the GitHub PRs widget (host-side) rather than opening a browser.
        var labels: [WidgetHeaderLabel] = []
        if let n = toReview, n > 0 { labels.append(Self.ghLabel(count: n, suffix: "to review")) }
        if let n = inReview, n > 0 { labels.append(Self.ghLabel(count: n, suffix: "in review")) }
        headerLabels = labels
    }

    /// Run a `gh search prs … --json url` query (with the PATH prefix) and return
    /// the result array's count, or nil on any failure (fail-soft — the caller
    /// omits that chip).
    private func count(services: WidgetBackgroundServices, query: String) async -> Int? {
        let cmd = "\(ghReviewPathPrefix) && \(query)"
        guard let result = try? await services.shell.run(command: cmd),
              result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return array.count
    }

    /// A GitHub-branded header label: mark + dark brand color + "N PR(s) <suffix>".
    private static func ghLabel(count n: Int, suffix: String) -> WidgetHeaderLabel {
        let noun = n == 1 ? "PR" : "PRs"
        return WidgetHeaderLabel(
            text: "\(n) \(noun) \(suffix)",
            iconImageData: githubMarkPNG,
            tint: .neutral
        )
    }

    /// This surface's GitHub `owner/repo` slugs — the root if it is itself a
    /// repo, else its depth-1 git subdirs — mirroring the widget's own
    /// enumeration (services.shell cwd is the workspace root on Home, a
    /// session's worktree container in a session). Deduped; empty when
    /// nothing resolves (→ no label). `-e` not `-d`: see `enumerateRepos()`
    /// (data-driven-session-surfaces s8) — a worktree's `.git` is a file.
    private func workspaceRepoSlugs(services: WidgetBackgroundServices) async -> [String] {
        let cmd = """
            \(ghReviewPathPrefix)
            if [ -e ".git" ]; then
              _url=$(git config --get remote.origin.url 2>/dev/null)
              [ -n "$_url" ] && printf '%s\\n' "$_url"
            else
              for _d in */; do
                [ -e "${_d}.git" ] || continue
                _url=$(git -C "${_d%/}" config --get remote.origin.url 2>/dev/null)
                [ -n "$_url" ] && printf '%s\\n' "$_url"
              done
            fi
            """
        guard let result = try? await services.shell.run(command: cmd),
              result.exitCode == 0 else { return [] }
        var slugs: [String] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let url = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let (owner, repo) = parseGitHubOwnerRepo(url) {
                slugs.append("\(owner)/\(repo)")
            }
        }
        return Array(Set(slugs))
    }

    /// The GitHub mark (50×50 PNG) embedded as base64 so the "to review" chip
    /// leads with the unambiguous brand logo instead of a generic SF Symbol.
    /// Decoded once; nil if decoding somehow fails (the chip then shows text
    /// only — still correct).
    static let githubMarkPNG: Data? = Data(base64Encoded: githubMarkPNGBase64)
}

extension GitHubPRsWidget: Work42WidgetBackground {
    /// Fresh agent per (session × widget) pair — the host owns the lifecycle.
    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        GitHubPRsReviewAgent()
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(GitHubPRsWidget())
    }
    return result
}
