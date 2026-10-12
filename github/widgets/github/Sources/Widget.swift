// Widget.swift — github pre-built widget (feat/generalizations-of-features.8).
//
// Renders one browser tab per entry in storage key `github/prs` (JSON array of
// {url, status, merged_at}), runs a background PR-watch loop entirely through
// `services.shell` (no direct Process calls), and delivers fingerprinted
// `[system event]`s via `task42 event` using the SAME fingerprint scheme as the
// deleted `PRWatchService` so existing `pending_updates` dedup entries carry over.
//
// RENDERING:
//   Empty state  → paste-URL form that writes to `github/prs` via storage.set.
//   One PR       → BrowserSurface (single tab, chrome-as-header via widget id key).
//   Two+ PRs     → BrowserSurface with replaceTabs for each entry; + wires to
//                  attach form; × calls detach (removes from storage).
//
// WATCHER (bug/widgets-in-background-are-not-working):
//   The watch loop has moved OFF the view path into GitHubBackgroundAgent, which
//   conforms to WidgetBackgroundAgent (Work42PluginKit). The host creates ONE
//   agent per (session × widget) pair, calls start(services:) when the session
//   is alive, and stop() on dormancy/quit — independently of view mounting.
//
//   GitHubPRWidget.activate/deactivate now handle VIEW concerns only:
//   services for the view, browserModel, selection state, BrowserSurfaceCache.
//   The widget conforms to Work42WidgetBackground so the host discovers and
//   starts the background agent (AC10 — no double-polling).
//
// STORAGE CONVENTION (SKILL.md):
//   Read any namespace: services.storage.get(namespace: "github", key: "prs")
//   Write own namespace (id = "github"): services.storage.set(key: "prs", …)
//   This widget's namespace IS "github" (id == folder slug == writable namespace).
//   services.storage.set(key: "prs", value:) writes directly to github/prs — no
//   shell indirection needed. Agents use `task42 storage set <id> github/prs ...`.

import AppKit
import Observation
import SwiftUI
import Work42PluginKit

// MARK: - PR data model (storage schema)

/// One attached PR — matches the JSON schema stored in `github/prs`.
struct PREntry: Codable, Sendable, Equatable {
    var url: String
    var status: String          // "open" | "merged" | "closed"
    var merged_at: String?      // ISO-8601 or nil

    /// Parse a `WidgetJSONValue.array` from `github/prs` into typed entries.
    static func decode(from value: WidgetJSONValue) -> [PREntry] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item -> PREntry? in
            guard case .object(let obj) = item,
                  case .string(let url) = obj["url"] else { return nil }
            let status: String
            if case .string(let s) = obj["status"] { status = s } else { status = "open" }
            let mergedAt: String?
            if case .string(let m) = obj["merged_at"] { mergedAt = m } else { mergedAt = nil }
            return PREntry(url: url, status: status, merged_at: mergedAt)
        }
    }

    /// Encode `[PREntry]` → `WidgetJSONValue.array`.
    static func encode(_ entries: [PREntry]) -> WidgetJSONValue {
        .array(entries.map { entry in
            .object([
                "url":       .string(entry.url),
                "status":    .string(entry.status),
                "merged_at": entry.merged_at.map { .string($0) } ?? .null,
            ])
        })
    }
}

// MARK: - GitHub PR URL parsing

/// Minimal GitHub PR URL parser (no import of Task42Core / Flow42Core).
struct PRRef: Sendable {
    var owner: String
    var repo: String
    var number: Int
    var displayName: String { "\(owner)/\(repo)#\(number)" }
    /// What the header chip and the browser tab show: "#299 · work42". Agent-facing messages keep `displayName`.
    var shortName: String { "#\(number) \u{00B7} \(repo)" }
    var inlineCommentsEndpoint: String { "repos/\(owner)/\(repo)/pulls/\(number)/comments" }
}

func parseGitHubPRRef(_ urlString: String) -> PRRef? {
    guard let u = URL(string: urlString),
          let host = u.host, host.lowercased() == "github.com" else { return nil }
    let parts = u.pathComponents.filter { $0 != "/" }
    // /owner/repo/pull/N
    guard parts.count >= 4,
          parts[2].lowercased() == "pull",
          let n = Int(parts[3]) else { return nil }
    return PRRef(owner: parts[0], repo: parts[1], number: n)
}

// MARK: - Lightweight PR snapshot for the watch-loop diff

/// Minimal snapshot of a PR's watchable state — built by parsing `gh pr view --json` output.
/// Mirrors the relevant subset of Flow42Core's `GitHubPRSnapshot` without depending on it.
struct PRSnapshot: Sendable {
    var number: Int
    var state: String       // OPEN / MERGED / CLOSED
    var headRefOid: String
    var mergedAt: String?
    var author: String      // PR author's login ("" when absent)
    var reviews: [Review]
    var comments: [Comment]
    var reviewComments: [InlineComment]
    var checks: [Check]

    struct Review: Sendable {
        var id: String; var author: String; var state: String; var body: String
        var submittedAt: String?
    }
    struct Comment: Sendable {
        var id: String; var author: String; var body: String
    }
    struct InlineComment: Sendable {
        var id: String; var author: String; var body: String
        var path: String?; var line: Int?
    }
    struct Check: Sendable {
        var name: String; var conclusion: String; var isComplete: Bool
        var isFailure: Bool {
            isComplete && Check.failingConclusions.contains(conclusion)
        }
        var isSuccess: Bool {
            isComplete && (conclusion == "SUCCESS" || conclusion == "NEUTRAL" || conclusion == "SKIPPED")
        }
        static let failingConclusions: Set<String> = [
            "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE",
        ]
    }
}

/// Aggregate of one PR's header-worthy state — feeds the session-header
/// labels (`WidgetBackgroundAgent.headerLabels`). Derived from a `PRSnapshot`
/// each watch cycle; stored on the agent's `@Observable` state so the host
/// strip re-renders when CI or reviews move.
struct PRHeaderState: Sendable, Equatable {
    var author: String
    var checksTotal: Int
    var checksFailed: Int
    var checksPending: Int
    var approvals: Int
    var changesRequested: Bool

    init(from snap: PRSnapshot) {
        author = snap.author
        checksTotal = snap.checks.count
        checksFailed = snap.checks.filter(\.isFailure).count
        checksPending = snap.checks.filter { !$0.isComplete }.count
        // Latest review per author decides their standing (GitHub semantics:
        // a newer APPROVED supersedes an older CHANGES_REQUESTED and vice
        // versa; COMMENTED never changes standing).
        var latest: [String: PRSnapshot.Review] = [:]
        for r in snap.reviews where r.state == "APPROVED" || r.state == "CHANGES_REQUESTED" {
            if let existing = latest[r.author],
               (existing.submittedAt ?? "") > (r.submittedAt ?? "") { continue }
            latest[r.author] = r
        }
        approvals = latest.values.filter { $0.state == "APPROVED" }.count
        changesRequested = latest.values.contains { $0.state == "CHANGES_REQUESTED" }
    }
}

// MARK: - JSON parsing from gh output

/// Parse `gh pr view --json number,state,headRefOid,mergedAt,reviews,comments,statusCheckRollup`
/// output into a `PRSnapshot`. Returns nil on any structural decode failure.
func parsePRSnapshot(from jsonString: String, prURL: String) -> PRSnapshot? {
    guard let data = jsonString.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let number = (obj["number"] as? Int) ?? 0
    let state = ((obj["state"] as? String) ?? "UNKNOWN").uppercased()
    let headRefOid = (obj["headRefOid"] as? String) ?? ""
    let mergedAt = obj["mergedAt"] as? String
    let author = decodeLogin(obj, key: "author")

    // Reviews
    var reviews: [PRSnapshot.Review] = []
    if let rawReviews = obj["reviews"] as? [[String: Any]] {
        for r in rawReviews {
            let id: String
            if let s = r["id"] as? String, !s.isEmpty { id = s }
            else { id = "\(decodeLogin(r, key: "author"))|\((r["submittedAt"] as? String) ?? "")|\((r["state"] as? String) ?? "")" }
            reviews.append(PRSnapshot.Review(
                id: id,
                author: decodeLogin(r, key: "author"),
                state: ((r["state"] as? String) ?? "").uppercased(),
                body: (r["body"] as? String) ?? "",
                submittedAt: r["submittedAt"] as? String
            ))
        }
    }

    // Issue-level comments
    var comments: [PRSnapshot.Comment] = []
    if let rawComments = obj["comments"] as? [[String: Any]] {
        for c in rawComments {
            let id: String
            if let s = c["id"] as? String, !s.isEmpty { id = s }
            else if let i = c["id"] as? Int { id = String(i) }
            else { id = "\(decodeLogin(c, key: "author"))|\((c["createdAt"] as? String) ?? "")" }
            comments.append(PRSnapshot.Comment(
                id: id,
                author: decodeLogin(c, key: "author"),
                body: (c["body"] as? String) ?? ""
            ))
        }
    }

    // Status check rollup (heterogeneous CheckRun / StatusContext)
    var checks: [PRSnapshot.Check] = []
    if let rawChecks = obj["statusCheckRollup"] as? [[String: Any]] {
        for ch in rawChecks {
            if let status = ch["status"] as? String {
                // CheckRun
                let done = status.uppercased() == "COMPLETED"
                let conclusion = done ? ((ch["conclusion"] as? String) ?? "").uppercased() : ""
                let name = (ch["name"] as? String) ?? ""
                if !name.isEmpty {
                    checks.append(PRSnapshot.Check(name: name, conclusion: conclusion, isComplete: done && !conclusion.isEmpty))
                }
            } else if let state = ch["state"] as? String {
                // StatusContext
                let raw = state.uppercased()
                let pending = raw.isEmpty || raw == "PENDING" || raw == "EXPECTED"
                let name = (ch["context"] as? String) ?? ""
                if !name.isEmpty {
                    checks.append(PRSnapshot.Check(name: name, conclusion: pending ? "" : raw, isComplete: !pending))
                }
            }
        }
    }

    return PRSnapshot(
        number: number, state: state, headRefOid: headRefOid, mergedAt: mergedAt,
        author: author,
        reviews: reviews, comments: comments, reviewComments: [], checks: checks
    )
}

/// Parse `gh api repos/{owner}/{repo}/pulls/{N}/comments` (paginated) output
/// into inline review comments. Returns [] on any failure.
func parseInlineComments(from jsonString: String) -> [PRSnapshot.InlineComment] {
    guard let data = jsonString.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return arr.compactMap { c in
        let id: String
        if let i = c["id"] as? Int { id = String(i) }
        else if let s = c["id"] as? String, !s.isEmpty { id = s }
        else { return nil }
        let author: String
        if let user = c["user"] as? [String: Any], let login = user["login"] as? String {
            author = login
        } else {
            author = (c["login"] as? String) ?? ""
        }
        let path = c["path"] as? String
        let line = (c["line"] as? Int) ?? (c["original_line"] as? Int)
        return PRSnapshot.InlineComment(
            id: id,
            author: author,
            body: (c["body"] as? String) ?? "",
            path: path,
            line: line
        )
    }
}

/// Decode `author` from a `gh` object — either `{"author": {"login": "x"}}` or `{"author": "x"}`.
private func decodeLogin(_ obj: [String: Any], key: String) -> String {
    if let nested = obj[key] as? [String: Any], let login = nested["login"] as? String { return login }
    if let bare = obj[key] as? String { return bare }
    return ""
}

// MARK: - Fingerprint scheme (mirrors PRWatchEvent — must match for dedup carry-over)

/// Build the set of baseline fingerprints for a snapshot (same logic as
/// `PRWatchEvent.baselineFingerprints`). These are seeded in-memory on first
/// observation so the first poll doesn't replay the entire PR history.
func baselineFingerprints(for snap: PRSnapshot) -> Set<String> {
    var fps = Set<String>()
    for r in snap.reviews { fps.insert("review:\(r.id)") }
    for c in snap.comments { fps.insert("comment:\(c.id)") }
    for ic in snap.reviewComments { fps.insert("review-comment:\(ic.id)") }
    for ch in snap.checks where ch.isComplete { fps.insert("check:\(ch.name):\(ch.conclusion)") }
    if let ag = allGreenFingerprint(for: snap.checks) { fps.insert(ag) }
    return fps
}

func allGreenFingerprint(for checks: [PRSnapshot.Check]) -> String? {
    guard !checks.isEmpty, checks.allSatisfy(\.isComplete), checks.allSatisfy(\.isSuccess) else { return nil }
    let names = checks.map(\.name).sorted().joined(separator: ",")
    return "checks:all-green:\(names)"
}

/// Compare `old` → `new` and return new (fingerprint, message) pairs for
/// events that need delivery. Returns [] for baseline (prior == nil).
func newEvents(from old: PRSnapshot?, to new: PRSnapshot, ref: PRRef) -> [(String, String)] {
    guard let old else { return [] }
    var out: [(String, String)] = []
    let tag = "PR \(ref.displayName)"
    let pr = new.number

    // 1. State transitions (reopened handled via newEvents not terminal block)
    if old.state != new.state {
        switch new.state {
        case "MERGED":
            // NOTE: merged is handled by the terminal-state block that runs every poll.
            break
        case "CLOSED":
            // NOTE: closed is handled by the terminal-state block too.
            break
        case "OPEN":
            if old.state == "CLOSED" || old.state == "MERGED" {
                out.append(("state:reopened:\(pr)", "\(tag) was reopened."))
            }
        default: break
        }
    }

    // 2. New reviews
    let oldReviewIDs = Set(old.reviews.map(\.id))
    for r in new.reviews where !oldReviewIDs.contains(r.id) {
        let who = r.author.isEmpty ? "someone" : "@\(r.author)"
        let decision = humanReviewState(r.state)
        let snippet = bodySnippet(r.body)
        let body = snippet.isEmpty ? "." : " — \"\(snippet)\""
        out.append(("review:\(r.id)", "\(tag) review by \(who): \(decision)\(body)"))
    }

    // 3. New issue-level comments
    let oldCommentIDs = Set(old.comments.map(\.id))
    for c in new.comments where !oldCommentIDs.contains(c.id) {
        let who = c.author.isEmpty ? "someone" : "@\(c.author)"
        let snippet = bodySnippet(c.body)
        let body = snippet.isEmpty
            ? "new comment from \(who)."
            : "comment from \(who): \"\(snippet)\""
        out.append(("comment:\(c.id)", "\(tag) \(body)"))
    }

    // 4. New inline review comments
    let oldInlineIDs = Set(old.reviewComments.map(\.id))
    for ic in new.reviewComments where !oldInlineIDs.contains(ic.id) {
        let who = ic.author.isEmpty ? "someone" : "@\(ic.author)"
        let snippet = bodySnippet(ic.body)
        let anchor: String
        if let path = ic.path, !path.isEmpty {
            anchor = ic.line.map { " on \(path):\($0)" } ?? " on \(path)"
        } else {
            anchor = ""
        }
        let bodyStr = snippet.isEmpty ? "." : " — \"\(snippet)\""
        out.append(("review-comment:\(ic.id)", "\(tag) inline comment by \(who)\(anchor)\(bodyStr)"))
    }

    // 5. CI / status checks
    var oldConclusions: [String: String] = [:]
    for ch in old.checks where ch.isComplete { oldConclusions[ch.name] = ch.conclusion }
    for ch in new.checks where ch.isFailure {
        if oldConclusions[ch.name] != ch.conclusion {
            out.append(("check:\(ch.name):\(ch.conclusion)",
                        "\(tag) CI failed: \(ch.name) (\(ch.conclusion.lowercased())) — push a fix and CI will re-run."))
        }
    }
    if let newAG = allGreenFingerprint(for: new.checks) {
        let oldAG = allGreenFingerprint(for: old.checks)
        if newAG != oldAG {
            let count = new.checks.count
            out.append((newAG,
                        "\(tag) CI is all green — \(count) check\(count == 1 ? "" : "s") passed."))
        }
    }

    return out
}

/// The terminal-state event (merged/closed) — runs every poll so a missed delivery
/// self-heals. Returns nil for OPEN. `task42 event` deduplicates via `pending_updates`.
func terminalStateEvent(for snap: PRSnapshot, ref: PRRef) -> (String, String)? {
    let tag = "PR \(ref.displayName)"
    let pr = snap.number
    switch snap.state {
    case "MERGED": return ("state:merged:\(pr)", "\(tag) was merged.")
    case "CLOSED": return ("state:closed:\(pr)", "\(tag) was closed without merging.")
    default: return nil
    }
}

private func humanReviewState(_ state: String) -> String {
    switch state.uppercased() {
    case "APPROVED": return "APPROVED"
    case "CHANGES_REQUESTED": return "CHANGES_REQUESTED"
    case "COMMENTED": return "commented"
    case "DISMISSED": return "dismissed"
    case "PENDING": return "pending"
    default: return state.isEmpty ? "reviewed" : state
    }
}

private func bodySnippet(_ body: String, limit: Int = 140) -> String {
    let collapsed = body
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > limit else { return collapsed }
    let cutoff = collapsed.index(collapsed.startIndex, offsetBy: limit)
    return collapsed[..<cutoff].trimmingCharacters(in: .whitespaces) + "…"
}

// MARK: - Shell PATH enrichment

/// Prepend common Homebrew / local dirs to PATH for the gh + task42 shell invocations.
/// The app may be launched via Finder with a minimal PATH that omits these.
private let enrichedPathPrefix = "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

// MARK: - GitHubBackgroundAgent

/// Per-(session × widget) background agent for the GitHub PR widget.
///
/// The host creates ONE instance per (session × widget) pair via
/// `GitHubPRWidget.makeBackgroundAgent()`, calls `start(services:)` when the
/// session becomes alive, and `stop()` on dormancy / layout removal / hot-reload /
/// app quit — decoupled from view mounting (AC1, AC3, AC4, AC10).
///
/// ## What lives here (moved from GitHubPRWidget)
/// - The 60-second poll loop (`startWatcher` / `poll`)
/// - `lastSeen` / `seededFingerprints` per-session state
/// - `github/prs` status/merged_at writes via `services.storage`
/// - `[system event]` delivery via `task42 event`
/// - Header label computation and storage (`headerLabels` — @Observable-backed
///   so the host's header-strip render pass registers a dependency)
///
/// ## What stays on GitHubPRWidget (view path)
/// - `activate` / `deactivate` — view services, browserModel, selection, popover
/// - `prs`, `syncTabs`, `loadAndSyncPRs` — browser tab management
/// - `attach` / `detach` — UI-driven PR list mutations
///
/// ## Idle-cheap contract (AC8)
/// A poll cycle where `github/prs` is empty or absent performs the storage read
/// ONLY — zero `gh` spawns. The `guard !currentPRs.isEmpty else { return }` gate
/// is the explicit enforcement point.
///
/// ## Header labels (authoritative source)
/// `headerLabels` replaces the defunct `Work42WidgetHeaderLabels` singleton.
/// The singleton's `headerStates` dict lived on the widget class (shared across
/// all sessions) — a cross-session contamination source. Each agent owns its own
/// `headerStates`, so labels are correctly session-scoped (AC3).
/// The GitHub mark as a small embedded PNG, base64-encoded, so header chips and widget icons show it with no
/// network and no bundle resources. Source: GitHub's official Invertocat from the brand kit
/// (https://brand.github.com/GitHub_Logos.zip, SVG/GitHub_Invertocat_Black.svg, the plain file, not the
/// _Clearspace one), shape unchanged, recoloured green #58BC51 with the cat filled black, 64 x 64 with no
/// transparent margin. One image for light and dark. It goes on a NEUTRAL chip: a chip with a brand fill makes
/// the host redraw the mark as a one-colour silhouette (a blank disc).
private let githubMarkPNGBase64 = "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"

/// Decoded once at file scope; nil only if the base64 is corrupt.
private let githubMarkPNG: Data? = Data(base64Encoded: githubMarkPNGBase64)

@Observable
@MainActor
final class GitHubBackgroundAgent: WidgetBackgroundAgent {

    // MARK: - WidgetBackgroundAgent requirement

    /// Session-scoped header label chips. @Observable-backed: mutating this dict
    /// in a poll cycle triggers only the header strip's render pass, not the whole
    /// widget grid. Empty until the first successful poll.
    var headerLabels: [WidgetHeaderLabel] = []

    // MARK: - Internal poll state (session-scoped — one instance per session)

    /// Last-seen snapshot per PR URL. Cleared on stop().
    private var lastSeen: [String: PRSnapshot] = [:]
    /// Baseline fingerprints per PR URL (seeded on first observation without
    /// event delivery, suppressing "replay" of pre-agent history). Cleared on stop().
    private var seededFingerprints: [String: Set<String>] = [:]
    /// Latest per-PR header aggregate, keyed by PR URL. Updated each poll cycle;
    /// drives `headerLabels` recomputation.
    private var headerStates: [String: PRHeaderState] = [:]

    /// The running poll loop task. nil when stopped.
    private var watchTask: Task<Void, Never>?

    // MARK: - WidgetBackgroundAgent lifecycle

    func start(services: WidgetBackgroundServices) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            // Brief initial delay so the view can render before the first poll.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                await self?.poll(services: services)
                // Cadence is the app-level PR-watch interval preference, read
                // live each cycle so a change in Settings → Plugins applies on
                // the next poll (defaults to 60s when unset).
                let seconds = Self.pollIntervalSeconds()
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    /// Poll cadence in seconds. Reads the app-wide PR-watch interval preference
    /// (`prWatch.pollIntervalSeconds`, the same `@AppStorage` key the
    /// Settings → Plugins "PR-watch interval" row writes), clamped to a sane
    /// range. Falls back to 60s when unset or out of range. The widget runs
    /// in-process, so `UserDefaults.standard` is the app's own defaults domain.
    private static func pollIntervalSeconds() -> Int {
        let stored = UserDefaults.standard.integer(forKey: "prWatch.pollIntervalSeconds")
        guard stored > 0 else { return 60 }
        return min(3600, max(15, stored))
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        // Clear all per-session state so a restarted agent starts fresh.
        lastSeen.removeAll()
        seededFingerprints.removeAll()
        headerStates.removeAll()
        headerLabels = []
    }

    // MARK: - Poll loop

    private func poll(services: WidgetBackgroundServices) async {
        // Load current PRs from task storage.
        let currentPRs: [PREntry]
        do {
            if let value = try await services.storage.get(namespace: "github", key: "prs") {
                currentPRs = PREntry.decode(from: value)
            } else {
                currentPRs = []
            }
        } catch {
            return // Storage unavailable — skip this cycle
        }

        // AC8 — idle-cheap: when github/prs is empty or absent, we perform the
        // storage read above ONLY. Zero gh spawns on idle sessions.
        guard !currentPRs.isEmpty else { return }

        var prsUpdated = false
        var updatedPRs = currentPRs

        for (idx, entry) in currentPRs.enumerated() {
            guard let ref = parseGitHubPRRef(entry.url) else { continue }
            let key = entry.url

            // Fetch snapshot via gh
            let ghJSON = "\(enrichedPathPrefix) && gh pr view \"\(entry.url)\" --json number,state,headRefOid,mergedAt,author,reviews,comments,statusCheckRollup"
            let prResult: WidgetShellResult
            do {
                prResult = try await services.shell.run(command: ghJSON)
            } catch {
                continue // timeout or spawn failure — skip this PR
            }

            if prResult.exitCode != 0 {
                // gh unavailable or unauthenticated — skip this PR.
                continue
            }

            guard var snap = parsePRSnapshot(from: prResult.stdout, prURL: entry.url) else { continue }

            // Fetch inline review comments (secondary call, degrades gracefully)
            let inlineCmd = "\(enrichedPathPrefix) && gh api \"\(ref.inlineCommentsEndpoint)\" --paginate 2>/dev/null"
            if let inlineResult = try? await services.shell.run(command: inlineCmd),
               inlineResult.exitCode == 0 {
                let inline = parseInlineComments(from: inlineResult.stdout)
                snap = PRSnapshot(
                    number: snap.number, state: snap.state, headRefOid: snap.headRefOid,
                    mergedAt: snap.mergedAt, author: snap.author,
                    reviews: snap.reviews, comments: snap.comments,
                    reviewComments: inline, checks: snap.checks
                )
            }

            // Update the per-PR header aggregate for this session's label strip.
            let newHeaderState = PRHeaderState(from: snap)
            if headerStates[key] != newHeaderState {
                headerStates[key] = newHeaderState
            }

            let prior = lastSeen[key]

            if prior == nil {
                // First observation: seed baseline fingerprints without delivering.
                seededFingerprints[key] = baselineFingerprints(for: snap)
            } else {
                // Subsequent poll: diff and deliver new events.
                let events = newEvents(from: prior, to: snap, ref: ref)
                for (fp, msg) in events {
                    let baseline = seededFingerprints[key] ?? []
                    guard !baseline.contains(fp) else { continue }
                    await deliverEvent(services: services, message: msg, fingerprint: fp)
                }
            }

            // Terminal-state block runs every poll (self-healing, deduped by task42 event).
            if let (fp, msg) = terminalStateEvent(for: snap, ref: ref) {
                await deliverEvent(services: services, message: msg, fingerprint: fp)
                // Update status / merged_at in storage when state changes.
                let newStatus = snap.state == "MERGED" ? "merged" : "closed"
                if updatedPRs[idx].status != newStatus {
                    updatedPRs[idx].status = newStatus
                    updatedPRs[idx].merged_at = snap.mergedAt
                    prsUpdated = true
                }
            } else if entry.status != "open" && snap.state == "OPEN" {
                // Reopened
                updatedPRs[idx].status = "open"
                updatedPRs[idx].merged_at = nil
                prsUpdated = true
            }

            lastSeen[key] = snap
        }

        // Persist status/merged_at updates back to storage when they changed.
        // Uses services.storage.set (own namespace "github") — no shell indirection.
        // Note: the view's prs array is NOT updated here; it refreshes on the next
        // activate → loadAndSyncPRs call (documented UX gap: tab status badges
        // update only on re-activate, not live while the panel is visible).
        if prsUpdated {
            do {
                try await services.storage.set(key: "prs", value: PREntry.encode(updatedPRs))
            } catch {
                // Write failed — skip; will retry on next poll.
            }
        }

        // Recompute the session-header labels from the freshly-updated headerStates.
        updateHeaderLabels(prs: currentPRs)
    }

    /// Recompute `headerLabels` from `headerStates`. Called at the end of each
    /// successful poll cycle. Emits ONE segmented group per attached PR (in the
    /// stored order), sharing `groupId = the PR url` so the host renders each PR
    /// as a single pill: a GitHub-marked id segment (`#N · repo`, the green
    /// mark on a neutral chip) that opens the PR, followed by its CI and review status
    /// segments (semantic tints) that deep-link to the checks / PR. Every PR
    /// gets at least its id segment, so none is lost.
    private func updateHeaderLabels(prs: [PREntry]) {
        var labels: [WidgetHeaderLabel] = []

        for entry in prs {
            guard let st = headerStates[entry.url] else { continue }
            let gid = entry.url
            let idText = parseGitHubPRRef(entry.url)?.shortName ?? entry.url

            // ID segment — the GitHub mark + "#N · repo" on a neutral chip.
            labels.append(WidgetHeaderLabel(
                text: idText,
                iconImageData: githubMarkPNG,
                tint: .neutral,
                url: URL(string: entry.url),
                groupId: gid
            ))

            // CI status segment.
            if st.checksTotal > 0 {
                let checksURL = URL(string: "\(entry.url)/checks")
                if st.checksFailed > 0 {
                    labels.append(WidgetHeaderLabel(
                        text: st.checksFailed == 1 ? "CI: 1 failing" : "CI: \(st.checksFailed) failing",
                        systemIcon: "xmark.circle.fill", tint: .failure, url: checksURL, groupId: gid
                    ))
                } else if st.checksPending > 0 {
                    labels.append(WidgetHeaderLabel(
                        text: "CI running", systemIcon: "clock.fill",
                        tint: .warning, url: checksURL, groupId: gid
                    ))
                } else {
                    labels.append(WidgetHeaderLabel(
                        text: "CI passing", systemIcon: "checkmark.circle.fill",
                        tint: .success, url: checksURL, groupId: gid
                    ))
                }
            }

            // Review status segment.
            if st.changesRequested {
                labels.append(WidgetHeaderLabel(
                    text: "Changes requested", systemIcon: "exclamationmark.bubble.fill",
                    tint: .warning, url: URL(string: entry.url), groupId: gid
                ))
            } else if st.approvals > 0 {
                labels.append(WidgetHeaderLabel(
                    text: st.approvals == 1 ? "1 approval" : "\(st.approvals) approvals",
                    systemIcon: "checkmark.seal.fill", tint: .success,
                    url: URL(string: entry.url), groupId: gid
                ))
            }
        }

        headerLabels = labels
    }

    // MARK: - Event delivery

    /// Deliver one event via the session's event command.
    ///
    /// - Task / code-review sessions: `task42 event "$WORK42_TASK_ID" '<msg>' --fingerprint '<fp>'`
    ///   (WORK42_TASK_ID is set by the shell context).
    ///
    /// When the env var is unset (Home surface or plain session), the command is
    /// skipped. Non-zero exit is logged but never crashes the watcher.
    private func deliverEvent(services: WidgetBackgroundServices, message: String, fingerprint: String) async {
        // Escape the message for sh single-quote embedding.
        let safeMsgParts = message.components(separatedBy: "'").joined(separator: "'\"'\"'")
        let safeFP = fingerprint.replacingOccurrences(of: "'", with: "'\"'\"'")
        // The `if [ -n ... ]` guard skips silently on Home/plain surfaces.
        let cmd = """
            \(enrichedPathPrefix)
            if [ -n "$WORK42_TASK_ID" ]; then
              task42 event "$WORK42_TASK_ID" '\(safeMsgParts)' --fingerprint '\(safeFP)'
            fi
            """
        _ = try? await services.shell.run(command: cmd)
    }
}

// MARK: - GitHubPRWidget

/// The GitHub PR widget — pre-built, installed by default (feat/generalizations-of-features.8).
///
/// Widget id:  `github`  (must match folder slug — enforced by the loader)
/// Storage ns: reads `github/prs` via `services.storage.get(namespace: "github", key: "prs")`;
///             writes `github/prs` via `services.storage.set(key: "prs", value:)` — the
///             widget's writable namespace IS "github" so no shell indirection needed.
///
/// Background: conforms to `Work42WidgetBackground` so the host creates a
/// `GitHubBackgroundAgent` per (session × widget) pair. The poll loop, event
/// delivery, and header labels all live on the agent. `activate`/`deactivate`
/// handle VIEW concerns only (AC10).
@Observable
@MainActor
final class GitHubPRWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "github"
    let title = "GitHub PR"
    let icon = "arrow.triangle.pull"
    var iconImageData: Data? { githubMarkPNG }

    // The `enabledLayouts` allow-list was removed from the SDK in data-driven-
    // session-surfaces s7 — this widget is available on every surface (it made
    // most sense on a session, but availability is now curated by the host's
    // per-type deny-list, not declared here).

    /// GitHub web pages, including repositories, pull requests, and their
    /// sub-routes, are rendered by this widget. The handler is intentionally
    /// navigation-only; attaching a PR remains an explicit action.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [
                    .regex(GitHubWidgetLinkSupport.webURLPattern),
                ],
                perform: { [weak self] url in
                    self?.openLink(url)
                }
            ),
        ]
    }

    // MARK: - Observed state (drives the view)

    /// Current PR list from `github/prs`. Updated by loadAndSyncPRs on activate
    /// and by attach/detach. The background agent also updates storage, but the
    /// view refreshes on re-activate (documented UX gap — no view-path poll per AC10).
    var prs: [PREntry] = []
    /// Link opened through the host's Open Link intent. This is deliberately
    /// view-only: it participates in the BrowserSurface tabs without being
    /// appended to `github/prs` or observed by the background PR watcher.
    var openedLinkURL: URL?
    /// Drives the attach-sheet presentation.
    var showingAttachForm: Bool = false

    // Highlight-to-comment (the + bubble, the composer popover, and
    // dictate-to-comment) is now owned by the SDK's `BrowserSurface`. This
    // widget contributes only a `WebSelectionResolver` (see
    // `makeGitHubSelectionResolver`) that turns a raw selection into a
    // "PR #N · path:Lx–Ly" label. No selection state lives here anymore.

    // MARK: - Internal (not observed)

    private var services: SessionServices?

    /// The `BrowserWidgetModel` stored from the `configure:` closure of `BrowserSurface`.
    /// Used by the open-link intent to select the matching tab. Set to nil on
    /// `deactivate()`.
    var browserModel: BrowserWidgetModel?

    /// Stable UUID → URL mapping so tab close → detach works.
    private var tabIDs: [String: UUID] = [:]

    // MARK: - Lifecycle (VIEW concerns only — AC10)
    //
    // The background poll loop has moved to GitHubBackgroundAgent. activate and
    // deactivate now handle only view-scoped concerns: session services for the
    // view, browser model, selection state, and BrowserSurfaceCache teardown.

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in
            await self?.loadAndSyncPRs()
        }
        // NOTE: startWatcher is NOT called here. The host background agent owns
        // the poll loop and calls GitHubBackgroundAgent.start(services:) separately.
        // This eliminates the double-polling bug described in AC10.
        //
        // The live tab-reconcile subscription is NOT started here either: it is
        // driven by the view's `.task` (see PRWidgetMainView) so it runs only
        // while the widget's tab is actually on screen — with an immediate check
        // on appear — instead of polling in the background when unviewed.
    }

    func deactivate() {
        // View-scoped teardown only — the background agent manages its own lifecycle.
        services = nil
        browserModel = nil
        openedLinkURL = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(PRWidgetMainView(widget: self, services: services))
    }

    // MARK: - Load PRs from storage

    func loadAndSyncPRs() async {
        guard let services else { return }
        do {
            if let value = try await services.storage.get(namespace: "github", key: "prs") {
                prs = PREntry.decode(from: value)
            } else {
                prs = []
            }
        } catch {
            // Storage unavailable (Home surface, no task, etc.) — stay empty.
            prs = []
        }
        syncTabs()
    }

    /// Re-read `github/prs` and, when it changed out-of-band (an agent, the CLI,
    /// or `task42 storage set github/prs`), append the new tab(s) and focus the
    /// newest — live, without a close/reopen. A no-op when the URL set is
    /// unchanged, so the open tabs never thrash on the poll.
    func refreshFromStorage() async {
        guard let services else { return }
        let latest: [PREntry]
        do {
            if let value = try await services.storage.get(namespace: "github", key: "prs") {
                latest = PREntry.decode(from: value)
            } else {
                latest = []
            }
        } catch {
            return  // storage briefly unavailable — keep the current tabs
        }
        let currentURLs = prs.map(\.url)
        let latestURLs = latest.map(\.url)
        guard currentURLs != latestURLs else { return }

        // Only auto-focus when appending to an EXISTING tab set. On first
        // population (empty → N, e.g. the immediate check on appear) let the tab
        // bar pick its default rather than hijacking selection to the last entry.
        let hadTabs = !currentURLs.isEmpty
        let addedURLs = latestURLs.filter { !currentURLs.contains($0) }
        prs = latest        // .onChange(displayedURLs) re-runs syncTabs()
        syncTabs()          // ensure the new tab exists before we select it
        if hadTabs, let newest = addedURLs.last {
            browserModel?.selectTab(stableTabID(for: newest))
        }
    }

    // MARK: - Tab sync

    /// The surface's model: the one `configure:` saved, else the cache entry under this widget's scope. The SDK
    /// keys each surface by `"<session id or home>/<widget id>"`, so the unscoped lookup finds nothing.
    private func liveBrowserModel() -> BrowserWidgetModel? {
        browserModel ?? BrowserSurface.model(forKey: id, scope: services?.sessionId ?? "home")
    }

    /// Sync the BrowserSurface model's tab list from the current `prs` array.
    func syncTabs() {
        guard let model = liveBrowserModel() else { return }
        let tabs: [BrowserTab] = displayedURLs.map { url in
            let urlString = url.absoluteString
            let ref = parseGitHubPRRef(urlString)
            let label = ref?.shortName ?? urlString
            return BrowserTab(id: stableTabID(for: urlString), url: url, title: label, icon: "arrow.triangle.pull")
        }
        model.replaceTabs(tabs)
    }

    /// Stored PR URLs followed by the transient Open Link destination, if it
    /// is not already attached. Keeping this composition in memory prevents a
    /// simple link click from acquiring task metadata semantics.
    var displayedURLs: [URL] {
        GitHubWidgetLinkSupport.displayedURLs(
            attached: prs.compactMap { URL(string: $0.url) },
            opened: openedLinkURL
        )
    }

    /// Navigate to a GitHub PR without attaching it to the task.
    func openLink(_ url: URL) {
        openedLinkURL = url
        syncTabs()
        browserModel?.selectTab(stableTabID(for: url.absoluteString))
    }

    func stableTabID(for url: String) -> UUID {
        if let existing = tabIDs[url] { return existing }
        let new = UUID()
        tabIDs[url] = new
        return new
    }

    func urlForTabID(_ tabID: UUID) -> String? {
        tabIDs.first(where: { $0.value == tabID })?.key
    }

    // MARK: - Attach

    /// Validate and attach a new PR URL. Returns an error string on failure, nil on success.
    func attach(urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "URL is empty." }
        guard parseGitHubPRRef(trimmed) != nil else {
            return "Not a GitHub PR URL. Expected https://github.com/owner/repo/pull/123."
        }
        guard URL(string: trimmed) != nil else { return "Not a valid web address." }
        guard !prs.contains(where: { $0.url == trimmed }) else { return nil }

        var updated = prs
        updated.append(PREntry(url: trimmed, status: "open", merged_at: nil))
        return await writePRs(updated)
    }

    // MARK: - Detach

    func detach(tabID: UUID) async {
        guard let urlString = urlForTabID(tabID) else { return }
        if !prs.contains(where: { $0.url == urlString }) {
            if openedLinkURL?.absoluteString == urlString { openedLinkURL = nil }
            tabIDs.removeValue(forKey: urlString)
            syncTabs()
            return
        }
        let updated = prs.filter { $0.url != urlString }
        tabIDs.removeValue(forKey: urlString)
        // Note: lastSeen and seededFingerprints live on the background agent.
        // The agent will naturally skip this URL on its next poll since it is
        // no longer in github/prs storage. Stale entries in the agent's
        // lastSeen/seededFingerprints are harmless until the agent is stopped.
        _ = await writePRs(updated)
    }

    // MARK: - Write PRs to storage

    /// Write the updated PR list to storage and refresh `self.prs`. Returns error string or nil.
    ///
    /// Uses `services.storage.set(key: "prs", value:)` which writes to THIS widget's own
    /// namespace — "github" (the widget id) — so the key `"prs"` lands at `github/prs`,
    /// exactly where the rest of the system reads it. No shell indirection needed.
    private func writePRs(_ updated: [PREntry]) async -> String? {
        guard let services else { return "Widget not active." }
        do {
            try await services.storage.set(key: "prs", value: PREntry.encode(updated))
        } catch {
            return "Failed to write PR list: \(error.localizedDescription)"
        }
        prs = updated
        syncTabs()
        return nil
    }
}

// MARK: - Work42WidgetBackground conformance

/// Opt-in background-execution capability (bug/widgets-in-background-are-not-working).
///
/// The host detects this conformance via `as? any Work42WidgetBackground` and calls
/// `makeBackgroundAgent()` once per (session × widget) pair when the session becomes
/// eligible. Each call MUST return a fresh, independent instance — shared state across
/// calls would reintroduce the first-mount-services singleton bug.
///
/// Header label decision: `Work42WidgetHeaderLabels` singleton conformance is DROPPED.
/// Rationale: the backing state (`headerStates`) has moved to `GitHubBackgroundAgent`
/// for per-session isolation (AC3). Keeping the singleton conformance would require
/// state duplication (widget AND agent each holding headerStates), which the spec
/// explicitly names as a reason to drop the singleton. The agent's `headerLabels` is
/// the authoritative source; the app reads it directly from the agent (host-side change
/// handled by another Worker in the app repo).
extension GitHubPRWidget: Work42WidgetBackground {
    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        // Fresh instance every call — per-session isolation (AC3).
        GitHubBackgroundAgent()
    }
}

// MARK: - PRWidgetMainView

/// Root view dispatched from `makeView`. Renders the BrowserSurface for stored
/// PRs or a transient Open Link destination; otherwise renders the empty state.
@MainActor
private struct PRWidgetMainView: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    var body: some View {
        Group {
            if widget.displayedURLs.isEmpty {
                PREmptyStateView(widget: widget, services: services)
            } else {
                PRBrowserView(widget: widget, services: services)
            }
        }
        // Live tab-reconcile, scoped to the view being on screen. `.task` runs
        // when the widget's tab is navigated to / first rendered and is cancelled
        // by SwiftUI when it leaves the screen — so we do an immediate check on
        // appear, then subscribe (poll) for out-of-band `github/prs` changes only
        // while visible. Runs in BOTH states so a first external attach flips the
        // empty state to the browser live.
        .task {
            await widget.refreshFromStorage()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                if Task.isCancelled { break }
                await widget.refreshFromStorage()
            }
        }
    }
}

// MARK: - PRBrowserView

/// Renders the BrowserSurface with one tab per PR in `widget.prs`.
@MainActor
private struct PRBrowserView: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    private var firstURL: URL {
        widget.displayedURLs.first ?? URL(string: "https://github.com")!
    }

    var body: some View {
        BrowserSurface(
            spec: BrowserSurfaceSpec(
                url: firstURL,
                // No isolation selector: `.logged-in .application-main` blanks the
                // whole page when the store has no GitHub session (nothing matches),
                // leaving no way to reach the Sign in chrome. Render the full page.
                selector: "",
                // Shared cookie store with the regular Browser widget — sign in
                // once anywhere, every browser-based widget inherits the session.
                dataStoreKey: "browser",
                title: "GitHub PR",
                icon: "arrow.triangle.pull"
            ),
            cacheKey: widget.id,
            // The SDK owns the whole highlight-to-comment affordance (bubble,
            // composer, dictate-to-comment). We supply ONLY the resolver that
            // maps a raw PR-page selection into "PR #N · path:Lx–Ly".
            services: services,
            selectionResolver: makeGitHubSelectionResolver(services: services),
            configure: { [weak widget] model in
                guard let widget else { return }
                // Store the model so the open-link intent can select tabs.
                widget.browserModel = model
                // Sync all PR tabs (replace the seeded first tab from spec).
                widget.syncTabs()
                // + opens the attach form.
                model.onNewTab = { [weak widget] in
                    widget?.showingAttachForm = true
                }
                // × removes the PR from storage.
                model.onTabClosed = { [weak widget] tabID in
                    Task { await widget?.detach(tabID: tabID) }
                }
            }
        )
        // Re-sync tabs when prs changes (out-of-band attach/detach or storage update).
        .onChange(of: widget.displayedURLs.map(\.absoluteString)) { _, _ in
            widget.syncTabs()
        }
        .sheet(isPresented: Binding(
            get: { widget.showingAttachForm },
            set: { widget.showingAttachForm = $0 }
        )) {
            PRAttachSheet(widget: widget, services: services)
        }
    }
}

// MARK: - GitHub selection resolver

/// The GitHub widget's entire contribution to highlight-to-comment: map a raw
/// PR-page selection into a precise "PR #N · path:L12–L18" source label. The
/// SDK's `BrowserSurface` owns the bubble, the composer popover, and
/// dictate-to-comment; it calls this resolver ONCE (async) right before the
/// comment reaches the composer, identically for a typed note and a dictated
/// one. Returning `nil` (not a PR page) falls back to the SDK's plain
/// page-title label.
///
/// Precise-anchor resolution (unchanged from the old bespoke path): shell
/// `gh pr diff <n> --repo owner/repo` via `services.shell` (cwd = the session
/// worktree; the runner enriches PATH + GH_TOKEN) and match the selection
/// against the unified diff with `PRDiffLocator` (a verbatim port of
/// the diff-location primitive). Degrades
/// in order: resolved anchor → DOM file hint (domContext.path) → PR number.
@MainActor
func makeGitHubSelectionResolver(services: SessionServices) -> WebSelectionResolver {
    { selection in
        guard let urlString = selection.pageURL?.absoluteString,
              let ref = parseGitHubPRRef(urlString) else {
            // Not a GitHub PR page — let the SDK use its plain label.
            return nil
        }
        // GitHub's diff DOM annotates rows with `data-path` / `data-tagsearch-path`,
        // which the SDK's generic scraper delivers as domContext.path / .tagsearch-path.
        let fileHint = selection.domContext["path"] ?? selection.domContext["tagsearch-path"]

        // Try the precise anchor first.
        // `--repo owner/repo` — the session cwd is the multi-repo CONTAINER
        // (not a git repo), so gh cannot infer the repo from the working
        // directory; a bare `gh pr diff <n>` fails there.
        if let result = try? await services.shell.run(
               command: "\(enrichedPathPrefix) && gh pr diff \(ref.number) --repo \(ref.owner)/\(ref.repo)"
           ),
           result.exitCode == 0,
           let anchor = PRDiffLocator.locate(
               patch: result.stdout, fileHint: fileHint, selection: selection.text
           ) {
            let lines = anchor.startLine == anchor.endLine
                ? "L\(anchor.startLine)"
                : "L\(anchor.startLine)–L\(anchor.endLine)"
            return ResolvedAnnotation(sourceLabel: "PR #\(ref.number) · \(anchor.filePath):\(lines)")
        }

        // Degrade: DOM file hint → bare PR number.
        if let hint = fileHint, !hint.isEmpty {
            let filename = (hint as NSString).lastPathComponent
            return ResolvedAnnotation(sourceLabel: "PR #\(ref.number) · \(filename)")
        }
        return ResolvedAnnotation(sourceLabel: "PR #\(ref.number)")
    }
}

// MARK: - PREmptyStateView

@MainActor
private struct PREmptyStateView: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var attaching = false

    var body: some View {
        VStack(spacing: DT.s16) {
            GitHubBrandMark(size: 32)

            Text("No PR yet")
                .font(.system(size: DT.f13, weight: .medium))

            Text("Once the worker pushes a branch, the PR link lands here. Or paste a GitHub PR URL to track it now — the PR is rendered inside Work42, sign in to GitHub once and the session is kept.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: DT.s8) {
                TextField("https://github.com/owner/repo/pull/123", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAttach)

                Button("Open in Work42", action: submitAttach)
                    .disabled(attaching || draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 360)

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitAttach() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !attaching else { return }
        attaching = true
        errorMessage = nil
        Task { @MainActor in
            defer { attaching = false }
            if let err = await widget.attach(urlString: trimmed) {
                errorMessage = err
            } else {
                draftURL = ""
            }
        }
    }
}

// MARK: - PRAttachSheet

/// Modal sheet shown when the `+` button is pressed in the chrome row.
@MainActor
private struct PRAttachSheet: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var attaching = false

    var body: some View {
        VStack(spacing: DT.s16) {
            GitHubBrandMark(size: 28)

            Text("Attach a GitHub PR")
                .font(.system(size: DT.f14, weight: .semibold))

            Text("Paste a GitHub PR URL. A new tab is added and the PR is embedded.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: DT.s8) {
                TextField("https://github.com/owner/repo/pull/123", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAttach)

                Button("Attach", action: submitAttach)
                    .disabled(attaching || draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 360)

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button("Cancel") {
                widget.showingAttachForm = false
                draftURL = ""
                errorMessage = nil
            }
            .buttonStyle(.bordered)
        }
        .padding(DT.s24)
        .frame(minWidth: 420)
    }

    private func submitAttach() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !attaching else { return }
        attaching = true
        errorMessage = nil
        Task { @MainActor in
            defer { attaching = false }
            if let err = await widget.attach(urlString: trimmed) {
                errorMessage = err
            } else {
                draftURL = ""
                widget.showingAttachForm = false
            }
        }
    }
}

/// Reusable in-widget identity mark. The SDK independently carries the same
/// bytes to the host's widget tile and browser-widget chrome.
private struct GitHubBrandMark: View {
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        if let data = githubMarkPNG, let image = NSImage(data: data) {
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

// MARK: - Widget entry-point ABI

// The two @_cdecl symbols the app's dlopen/dlsym loader expects.
// `nonisolated(unsafe)` local is required because MainActor.assumeIsolated
// cannot return an UnsafeMutableRawPointer directly (not Sendable — see
// reference_cdecl_mainactor_assumeisolated_pointer_sendable in MEMORY.md).

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(GitHubPRWidget())
    }
    return result
}


// MARK: - PRDiffLocator
//
// Self-contained diff-location primitive — widget dylibs link only
// Work42UI + Work42PluginKit, so the pure locator algorithm is duplicated here.
// A small, stable match/ambiguity contract; keep this
// copy in sync. Contract summary: parse the unified diff file-by-file and
// hunk-by-hunk; match the whitespace-trimmed selection lines as a contiguous
// run; report new-side numbers for added runs, old-side for removed, new-side
// (fallback old) for mixed/context; fileHint restricts the search
// suffix-tolerantly; ambiguous multi-file matches with no hint return nil.

private nonisolated enum PRDiffChangeKind: String, Sendable, Equatable {
    case added, removed, context
}

private nonisolated struct PRDiffAnchor: Sendable, Equatable {
    let filePath: String
    let startLine: Int
    let endLine: Int
    let change: PRDiffChangeKind
}

private nonisolated enum PRDiffLocator {

    static func locate(patch: String, fileHint: String?, selection: String) -> PRDiffAnchor? {
        let selectionLines = selection
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !selectionLines.isEmpty else { return nil }

        let files = parse(patch: patch)
        guard !files.isEmpty else { return nil }

        let candidates: [ParsedFile]
        if let fileHint, !fileHint.trimmingCharacters(in: .whitespaces).isEmpty {
            let hinted = files.filter { pathMatchesHint($0.path, hint: fileHint) }
            candidates = hinted.isEmpty ? files : hinted
        } else {
            candidates = files
        }

        var matches: [PRDiffAnchor] = []
        for file in candidates {
            for anchor in matchesIn(file: file, selectionLines: selectionLines) {
                matches.append(anchor)
                if fileHint != nil { return anchor }
            }
        }

        if matches.isEmpty { return nil }
        if matches.count == 1 { return matches[0] }
        let distinct = Set(matches.map { "\($0.filePath)|\($0.startLine)|\($0.endLine)|\($0.change.rawValue)" })
        if distinct.count == 1 { return matches[0] }
        return nil
    }

    private struct BodyLine {
        let kind: PRDiffChangeKind
        let content: String
        let oldLine: Int?
        let newLine: Int?
    }

    private struct ParsedFile {
        var path: String
        var lines: [BodyLine]
    }

    private static func parse(patch: String) -> [ParsedFile] {
        var files: [ParsedFile] = []
        var current: ParsedFile?
        var oldCounter = 0
        var newCounter = 0
        var inHunk = false

        func flush() {
            if let c = current { files.append(c) }
        }

        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix("diff --git ") {
                flush()
                current = ParsedFile(path: pathFromDiffGit(rawLine) ?? "", lines: [])
                inHunk = false
                continue
            }
            if rawLine.hasPrefix("+++ ") {
                if let p = pathFromPlusPlus(rawLine), current != nil {
                    current?.path = p
                }
                inHunk = false
                continue
            }
            if rawLine.hasPrefix("--- ") {
                inHunk = false
                continue
            }
            if rawLine.hasPrefix("@@") {
                if let (oldStart, newStart) = parseHunkHeader(rawLine) {
                    oldCounter = oldStart
                    newCounter = newStart
                    inHunk = true
                } else {
                    inHunk = false
                }
                continue
            }
            guard inHunk, current != nil else { continue }
            if rawLine.hasPrefix("\\") { continue }

            guard let marker = rawLine.first else {
                current?.lines.append(BodyLine(kind: .context, content: "",
                                               oldLine: oldCounter, newLine: newCounter))
                oldCounter += 1
                newCounter += 1
                continue
            }
            let body = String(rawLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            switch marker {
            case "+":
                current?.lines.append(BodyLine(kind: .added, content: body,
                                               oldLine: nil, newLine: newCounter))
                newCounter += 1
            case "-":
                current?.lines.append(BodyLine(kind: .removed, content: body,
                                               oldLine: oldCounter, newLine: nil))
                oldCounter += 1
            case " ":
                current?.lines.append(BodyLine(kind: .context, content: body,
                                               oldLine: oldCounter, newLine: newCounter))
                oldCounter += 1
                newCounter += 1
            default:
                inHunk = false
            }
        }
        flush()
        return files
    }

    /// Edge-tolerant line comparison: a browser drag routinely starts/ends
    /// mid-word, so the FIRST selection line may be a clipped tail of its diff
    /// line (suffix match) and the LAST a clipped head (prefix match). Middle
    /// lines must match exactly. Single-line selections use containment when
    /// long enough to be unambiguous (>= 8 chars), exact equality otherwise.
    /// (This is more lenient than an exact-line match —
    /// real selections kept failing on clipped edges.)
    private static func lineMatches(
        _ diffLine: String, _ selLine: String, index j: Int, count n: Int
    ) -> Bool {
        if n == 1 {
            if selLine.count >= 8 { return diffLine.contains(selLine) }
            return diffLine == selLine
        }
        if j == 0 { return diffLine == selLine || diffLine.hasSuffix(selLine) }
        if j == n - 1 { return diffLine == selLine || diffLine.hasPrefix(selLine) }
        return diffLine == selLine
    }

    private static func matchesIn(file: ParsedFile, selectionLines: [String]) -> [PRDiffAnchor] {
        let n = selectionLines.count
        let body = file.lines
        guard body.count >= n else { return [] }
        var results: [PRDiffAnchor] = []

        var i = 0
        while i + n <= body.count {
            var matched = true
            for j in 0..<n where !lineMatches(body[i + j].content, selectionLines[j], index: j, count: n) {
                matched = false
                break
            }
            if matched {
                let run = Array(body[i..<(i + n)])
                if let anchor = anchor(forRun: run, path: file.path) {
                    results.append(anchor)
                }
                i += n
            } else {
                i += 1
            }
        }
        return results
    }

    private static func anchor(forRun run: [BodyLine], path: String) -> PRDiffAnchor? {
        guard !run.isEmpty else { return nil }
        let allAdded = run.allSatisfy { $0.kind == .added }
        let allRemoved = run.allSatisfy { $0.kind == .removed }

        if allAdded {
            let nums = run.compactMap { $0.newLine }
            guard let lo = nums.min(), let hi = nums.max() else { return nil }
            return PRDiffAnchor(filePath: path, startLine: lo, endLine: hi, change: .added)
        }
        if allRemoved {
            let nums = run.compactMap { $0.oldLine }
            guard let lo = nums.min(), let hi = nums.max() else { return nil }
            return PRDiffAnchor(filePath: path, startLine: lo, endLine: hi, change: .removed)
        }
        let newNums = run.compactMap { $0.newLine }
        if let lo = newNums.min(), let hi = newNums.max() {
            return PRDiffAnchor(filePath: path, startLine: lo, endLine: hi, change: .context)
        }
        let oldNums = run.compactMap { $0.oldLine }
        guard let lo = oldNums.min(), let hi = oldNums.max() else { return nil }
        return PRDiffAnchor(filePath: path, startLine: lo, endLine: hi, change: .context)
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        guard let firstAt = line.range(of: "@@") else { return nil }
        let afterFirst = line[firstAt.upperBound...]
        guard let secondAt = afterFirst.range(of: "@@") else { return nil }
        let inner = afterFirst[..<secondAt.lowerBound].trimmingCharacters(in: .whitespaces)
        var oldStart: Int?
        var newStart: Int?
        for token in inner.split(separator: " ") {
            if token.hasPrefix("-") {
                oldStart = leadingInt(String(token.dropFirst()))
            } else if token.hasPrefix("+") {
                newStart = leadingInt(String(token.dropFirst()))
            }
        }
        guard let o = oldStart, let nw = newStart else { return nil }
        return (o, nw)
    }

    private static func leadingInt(_ s: String) -> Int? {
        let head = s.prefix { $0.isNumber }
        return Int(head)
    }

    private static func pathFromDiffGit(_ line: String) -> String? {
        guard let bRange = line.range(of: " b/") else { return nil }
        let path = String(line[bRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func pathFromPlusPlus(_ line: String) -> String? {
        var rest = String(line.dropFirst(4))
        if let tab = rest.firstIndex(of: "\t") {
            rest = String(rest[..<tab])
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest == "/dev/null" { return nil }
        if rest.hasPrefix("b/") { rest = String(rest.dropFirst(2)) }
        return rest.isEmpty ? nil : rest
    }

    private static func pathMatchesHint(_ path: String, hint: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces)
        let h = hint.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || h.isEmpty { return false }
        if p == h { return true }
        if p.hasSuffix(h) || h.hasSuffix(p) { return true }
        let pLast = (p as NSString).lastPathComponent
        let hLast = (h as NSString).lastPathComponent
        if pLast == hLast { return true }
        return false
    }
}
