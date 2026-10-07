// Linear42Logic.swift — pure helpers (Foundation only, unit-tested standalone
// via linear42/Tests/LogicTests).

import Foundation

/// Extracts a Linear issue key ("WOR-123", upper-cased) from either a bare key
/// or a linear.app URL such as
/// `https://linear.app/work42/issue/WOR-123/some-slug`. Nil when neither fits.
func linearIssueKey(from input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let key = normalizedKey(trimmed) { return key }
    guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
          host == "linear.app" || host.hasSuffix(".linear.app")
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    // .../issue/<KEY>/<slug>: prefer the component right after "issue".
    if let i = parts.firstIndex(where: { $0.lowercased() == "issue" }), i + 1 < parts.count,
       let key = normalizedKey(parts[i + 1]) {
        return key
    }
    return parts.lazy.compactMap(normalizedKey).first
}

/// `[A-Za-z][A-Za-z0-9]*-[0-9]+` -> upper-cased, else nil.
private func normalizedKey(_ s: String) -> String? {
    guard let dash = s.lastIndex(of: "-") else { return nil }
    let team = s[s.startIndex..<dash]
    let number = s[s.index(after: dash)...]
    guard let first = team.first, first.isLetter, first.isASCII,
          team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
          !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    return s.uppercased()
}

/// `https://linear.app/<workspace>/issue/<KEY>` — the page the Issue tab shows
/// before the issue has been resolved through the CLI.
func linearIssueURL(workspace: String, key: String) -> String {
    let ws = workspace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspace
    return "https://linear.app/\(ws)/issue/\(key)"
}

// MARK: - Stage -> Linear state

/// One workflow state of a Linear team.
struct LinearState: Equatable, Sendable {
    var name: String
    var type: String      // triage | backlog | unstarted | started | completed | canceled
    var position: Double
}

enum StageStateResolution: Equatable, Sendable {
    /// Move the issue to this exact state name.
    case move(String)
    /// Nothing to push for this stage (no matching state, or an unmapped stage).
    case skip
    /// Config pinned a state name the team doesn't have.
    case missingOverride(String)
}

/// The Linear state a workflow stage maps to. A config override
/// (`stage_states.<TEAM>.<Stage>`) pins an exact state name; otherwise the stage
/// resolves by state TYPE, taking the lowest-`position` match, so extra columns
/// added in Linear never break the mapping:
///   Planning -> unstarted · In-Progress, Testing -> started ·
///   Human Review -> a started state named like "*review*" (else skip) ·
///   Done -> completed.
func resolveStageState(
    stage: String,
    teamKey: String,
    states: [LinearState],
    stageStates: [String: [String: String]]
) -> StageStateResolution {
    let overrides = stageStates.first { $0.key.caseInsensitiveCompare(teamKey) == .orderedSame }?.value
    if let pinned = overrides?[stage] {
        return states.contains { $0.name == pinned } ? .move(pinned) : .missingOverride(pinned)
    }
    func first(where predicate: (LinearState) -> Bool) -> StageStateResolution {
        guard let match = states.filter(predicate).min(by: { $0.position < $1.position }) else { return .skip }
        return .move(match.name)
    }
    switch stage {
    case "Planning": return first { $0.type == "unstarted" }
    case "In-Progress", "Testing": return first { $0.type == "started" }
    case "Human Review": return first { $0.type == "started" && $0.name.localizedCaseInsensitiveContains("review") }
    case "Done": return first { $0.type == "completed" }
    default: return .skip
    }
}

// MARK: - Approval read-back

/// Whether a poll should treat the Linear issue's state change as plan approval.
/// Only a change INTO a `started` state while the session sits in Planning, after
/// the issue was already observed once (`lastStateType != nil`, so binding an
/// already-in-progress issue is never an approval), with a spec doc and at least
/// one sub-issue in place.
func shouldApproveFromLinear(
    stage: String?,
    approvedAtPresent: Bool,
    lastStateType: String?,
    currentStateType: String,
    hasSpecDoc: Bool,
    hasSubIssues: Bool
) -> Bool {
    stage == "Planning"
        && !approvedAtPresent
        && lastStateType != nil
        && lastStateType != "started"
        && currentStateType == "started"
        && hasSpecDoc
        && hasSubIssues
}

// MARK: - Issue payload

struct LinearSubIssue: Equatable, Sendable {
    var key: String
    var title: String
    var description: String
    var stateName: String
    var stateType: String
    /// Mirrors the Testing gate's `done == true` check: only a `completed`
    /// state counts (canceled does not).
    var done: Bool { stateType == "completed" }
}

struct LinearIssuePayload: Equatable, Sendable {
    var id: String
    var key: String
    var url: String
    var title: String
    var stateName: String
    var stateType: String
    var teamKey: String
    var states: [LinearState]
    var children: [LinearSubIssue]
}

/// The GraphQL document the sync agent runs once per poll: the issue, its team's
/// workflow states, and its sub-issues. `children(first: 100)` is the documented cap.
let linearIssueQuery = """
query($id: String!) { issue(id: $id) { id identifier url title \
state { name type } \
team { key states { nodes { name type position } } } \
children(first: 100) { nodes { identifier title description state { name type } } } } }
"""

/// Decodes `{"data":{"issue":{...}}}` as printed by `linear api`. Nil when the
/// shape isn't what the query asks for (treated as a failed poll by the caller).
func parseIssuePayload(_ data: Data) -> LinearIssuePayload? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let issue = (root["data"] as? [String: Any])?["issue"] as? [String: Any],
          let id = issue["id"] as? String,
          let key = issue["identifier"] as? String,
          let url = issue["url"] as? String,
          let state = issue["state"] as? [String: Any],
          let stateName = state["name"] as? String,
          let stateType = state["type"] as? String,
          let team = issue["team"] as? [String: Any],
          let teamKey = team["key"] as? String
    else { return nil }
    let stateNodes = ((team["states"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    let states = stateNodes.compactMap { node -> LinearState? in
        guard let name = node["name"] as? String, let type = node["type"] as? String else { return nil }
        return LinearState(name: name, type: type, position: (node["position"] as? Double) ?? 0)
    }
    let childNodes = ((issue["children"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    let children = childNodes.compactMap { node -> LinearSubIssue? in
        guard let childKey = node["identifier"] as? String,
              let childState = node["state"] as? [String: Any],
              let childStateName = childState["name"] as? String,
              let childStateType = childState["type"] as? String
        else { return nil }
        return LinearSubIssue(
            key: childKey,
            title: (node["title"] as? String) ?? "",
            description: (node["description"] as? String) ?? "",
            stateName: childStateName,
            stateType: childStateType
        )
    }
    return LinearIssuePayload(
        id: id, key: key, url: url, title: (issue["title"] as? String) ?? "",
        stateName: stateName, stateType: stateType, teamKey: teamKey,
        states: states, children: children
    )
}

// MARK: - Shell

/// Widget shells inherit the app's PATH, which for a Finder-launched app is bare plus
/// Homebrew. The `linear` CLI is just as often installed to `~/.local/bin` (the official
/// installer, a manual download) or `~/.cargo/bin`; appending them keeps a user-level
/// install from reading as "CLI not installed". Appended, so a Homebrew copy still wins.
let linearCLIPathPrefix = "export PATH=\"$PATH:$HOME/.local/bin:$HOME/.cargo/bin\"; "

/// POSIX single-quote escaping for a value interpolated into a `/bin/sh -c` line.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
