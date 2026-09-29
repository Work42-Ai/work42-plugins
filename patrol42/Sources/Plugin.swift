// Plugin.swift — patrol42's compiled onCreate session hook
// (patrol42-plugin-conversion, s4).
//
// Reproduces the imperative creation work the built-in code-review path
// (work42/Sources/Work42App/Sessions/SessionFactory.ensureCodeReviewSession)
// used to do, now trigger-independent: resolve the GitHub PR URL, find the
// workspace sub-repo whose `origin` matches the PR, fetch the PR head
// (`refs/pull/<N>/head`) there and check it out detached, seed the
// `github/prs` storage the github widget + Done gate read, and link the
// review To-Do.
//
// `review/pr_url` is NOT written here — it is seeded declaratively from
// session-types/code-review.json's `pr_url` arg (SessionMint's generic
// arg->storage path) before onCreate ever runs. The arg still reaches this
// hook via `context.params["pr_url"]`.
//
// A plugin hooks dylib links only Work42WidgetKit, so it cannot reach
// Work42Core's Work42Link / RepoDiscovery / TodoSessionLink directly — PR
// parsing is done in-hook and every side effect goes through `context.shell`
// (`git ...`, `work42 storage set`, `work42 todos add`), the CLI-mediated
// equivalents, exactly as task42's hook does.
//
// `work42 todos add` does not dedupe by url the way TodoSessionLink.ensureTodo
// does — safe here because onCreate only fires on a genuinely new session
// insert (SessionMint's `guard inserted`), and code-review creation is
// idempotent by the PR key (re-opening a PR loads the existing session, so the
// hook never re-fires for the same PR).

import Foundation
import Work42WidgetKit

final class Patrol42Hooks: Work42SessionHooks {
    func onCreate(_ context: SessionCreateContext) async throws {
        guard case let .string(prURL)? = context.params["pr_url"],
              !prURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WidgetServiceError(
                message: "code-review requires a pr_url param",
                suggestion: "invoke the review-pr intent (or `work42 session new`) with a GitHub PR URL"
            )
        }

        guard let pr = Self.parsePR(prURL) else {
            throw WidgetServiceError(
                message: "not a GitHub PR URL: \"\(prURL)\"",
                suggestion: "expected github.com/<owner>/<repo>/pull/<N>"
            )
        }

        // Find the workspace sub-repo whose origin is this PR's repo.
        guard let repoPath = try await Self.matchRepo(pr, under: context.worktreePath, shell: context.shell) else {
            throw WidgetServiceError(
                message: "no workspace repository matches \(pr.owner)/\(pr.repo) for PR #\(pr.number)",
                suggestion: "open this PR from a workspace that contains its repository"
            )
        }

        // Fetch the PR head + check it out detached (the same stable pull ref
        // the old WorktreeEngine.existingRef path used). Fork PRs are covered:
        // refs/pull/<N>/head resolves regardless of the PR's source fork.
        let q = Self.shellQuote
        let fetch = try await context.shell.run(
            command: "git -C \(q(repoPath)) fetch origin refs/pull/\(pr.number)/head"
        )
        guard fetch.exitCode == 0 else {
            throw WidgetServiceError(
                message: "git fetch of PR #\(pr.number) failed (exit \(fetch.exitCode)): \(fetch.stderr)",
                suggestion: "check the PR number and that `origin` is reachable in \(repoPath)"
            )
        }
        let checkout = try await context.shell.run(
            command: "git -C \(q(repoPath)) checkout FETCH_HEAD"
        )
        guard checkout.exitCode == 0 else {
            throw WidgetServiceError(
                message: "git checkout of PR #\(pr.number) failed (exit \(checkout.exitCode)): \(checkout.stderr)",
                suggestion: "the fetched ref could not be checked out into \(repoPath)"
            )
        }

        // Seed github/prs (the github widget + Done gate read it). Written via
        // the CLI because the hook's storage service writes only the plugin's
        // own namespace — github/prs is a cross-namespace seed.
        let prsJSON = Self.githubPrsJSON(prURL: prURL)
        let seed = try await context.shell.run(
            command: "work42 storage set github/prs \(q(prsJSON))"
        )
        guard seed.exitCode == 0 else {
            throw WidgetServiceError(
                message: "seeding github/prs failed (exit \(seed.exitCode)): \(seed.stderr)",
                suggestion: "check `work42` is on PATH and the session resolves"
            )
        }

        // Link the review To-Do (same title + deep-link url as the built-in
        // TodoSessionLink path). Fail-soft: a To-Do failure does not invalidate
        // the review session.
        let title = "PR Review: \(pr.owner)/\(pr.repo)#\(pr.number)"
        let todoURL = "work42://code-review?pr=\(prURL)"
        _ = try? await context.shell.run(
            command: "work42 todos add --title \(q(title)) --url \(q(todoURL))"
        )
    }

    // MARK: - PR URL parsing

    struct PR: Equatable { let owner: String; let repo: String; let number: String }

    /// Parse `https://github.com/<owner>/<repo>/pull/<N>` (tolerating a
    /// trailing `/files`, `#fragment`, or `?query`). Owner/repo are lower-cased
    /// so origin comparison is case-insensitive, matching Work42Link.
    static func parsePR(_ raw: String) -> PR? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        guard let range = s.range(of: "github.com/") else { return nil }
        let path = s[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.count >= 4, path[2] == "pull",
              path[3].allSatisfy(\.isNumber), !path[3].isEmpty else { return nil }
        return PR(owner: path[0].lowercased(), repo: path[1].lowercased(), number: path[3])
    }

    /// Parse an `owner/repo` pair out of a git remote origin URL
    /// (`git@github.com:owner/repo.git` or `https://github.com/owner/repo.git`),
    /// lower-cased and `.git`-stripped, or nil when it is not a GitHub origin.
    static func parseOwnerRepo(fromOrigin origin: String) -> (owner: String, repo: String)? {
        var s = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let marker = s.contains("github.com:") ? "github.com:" : "github.com/"
        guard let range = s.range(of: marker) else { return nil }
        let parts = s[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0].lowercased(), parts[1].lowercased())
    }

    // MARK: - Repo matching

    /// The absolute path of the sub-repo (a worktree child directory, or the
    /// container itself for a single-repo workspace) whose `origin` remote is
    /// `pr.owner/pr.repo`, or nil when none matches.
    static func matchRepo(
        _ pr: PR, under worktreePath: String, shell: any WidgetShellService
    ) async throws -> String? {
        for candidate in repoCandidates(under: worktreePath) {
            let result = try await shell.run(
                command: "git -C \(shellQuote(candidate)) config --get remote.origin.url"
            )
            guard result.exitCode == 0 else { continue }
            guard let parsed = parseOwnerRepo(fromOrigin: result.stdout) else { continue }
            if parsed.owner == pr.owner && parsed.repo == pr.repo { return candidate }
        }
        return nil
    }

    /// Candidate repo directories: every depth-1 child of the container that
    /// holds a `.git` (multi-repo workspaces), plus the container itself when
    /// it is a lone repo. Absolute paths.
    static func repoCandidates(under worktreePath: String) -> [String] {
        let fm = FileManager.default
        var candidates: [String] = []
        if let children = try? fm.contentsOfDirectory(atPath: worktreePath) {
            for name in children.sorted() where !name.hasPrefix(".") {
                let child = (worktreePath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
                if fm.fileExists(atPath: (child as NSString).appendingPathComponent(".git")) {
                    candidates.append(child)
                }
            }
        }
        if candidates.isEmpty,
           fm.fileExists(atPath: (worktreePath as NSString).appendingPathComponent(".git")) {
            candidates.append(worktreePath)
        }
        return candidates
    }

    // MARK: - Encoding helpers

    /// The canonical-JSON `github/prs` seed: a one-element array with the PR
    /// url + an `open` status (the PR-watch loop advances it later).
    static func githubPrsJSON(prURL: String) -> String {
        let value: WidgetJSONValue = .array([.object([
            "url": .string(prURL),
            "status": .string("open"),
        ])])
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// POSIX single-quote shell escaping for a value interpolated into a
    /// `/bin/sh -c` command line — wraps in single quotes, escaping an embedded
    /// `'` as `'\''`. Matches task42's hook.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Plugin entry-point ABI

// The two @_cdecl symbols the app's dlopen/dlsym loader expects (mirrors
// task42's work42_plugin_main / work42_plugin_sdk_version pair).
// `nonisolated(unsafe)` local is required because MainActor.assumeIsolated
// cannot return an UnsafeMutableRawPointer directly (not Sendable).

@_cdecl("work42_plugin_sdk_version")
public func work42_plugin_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_plugin_main")
public func work42_plugin_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = PluginEntryPoint.register(Patrol42Hooks())
    }
    return result
}
