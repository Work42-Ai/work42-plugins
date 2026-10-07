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
    /// The state's color in Linear (`#RRGGBB`), as sent; check with `validHexColor`.
    var color: String? = nil
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


// MARK: - Several issues per session

/// Storage address (`namespace/key`) of one issue's value: `linear/issues/<KEY>/<name>`.
func issueAddress(_ key: String, _ name: String) -> String { "linear/issues/\(key)/\(name)" }

/// The flat keys that predate multi-issue sessions; each moves under `linear/issues/<KEY>/`.
let flatIssueKeyNames = ["issue", "spec_doc", "testing_doc", "last_state_type", "pushed_stage"]

/// How to move a single-issue session's flat keys under the bound issue: copy each, write the index,
/// and only then delete the flat keys, so a failure part-way leaves the old keys readable.
struct FlatMigrationPlan: Equatable {
    var copies: [(from: String, to: String)]
    var keys: [String]
    var deletes: [String]

    static func == (lhs: FlatMigrationPlan, rhs: FlatMigrationPlan) -> Bool {
        lhs.keys == rhs.keys && lhs.deletes == rhs.deletes
            && lhs.copies.map(\.from) == rhs.copies.map(\.from) && lhs.copies.map(\.to) == rhs.copies.map(\.to)
    }
}

/// Nil when there is nothing to migrate: the index already exists, no flat key is present, or the flat
/// `linear/issue` that names the issue is missing (`issueKey` nil).
func flatMigrationPlan(issueKey: String?, presentFlat: [String], hasIndex: Bool) -> FlatMigrationPlan? {
    guard !hasIndex, let issueKey else { return nil }
    let names = flatIssueKeyNames.filter { presentFlat.contains($0) }
    guard !names.isEmpty else { return nil }
    return FlatMigrationPlan(
        copies: names.map { (from: "linear/\($0)", to: issueAddress(issueKey, $0)) },
        keys: [issueKey],
        deletes: names.map { "linear/\($0)" }
    )
}

/// The attached keys from `linear/issue_keys`: valid keys only, normalised, in stored order.
func parseKeyList(_ value: Any?) -> [String] {
    guard let array = value as? [Any] else { return [] }
    return array.compactMap { ($0 as? String).flatMap(linearIssueKey(from:)) }
}

func appendingKey(_ keys: [String], _ key: String) -> [String] {
    keys.contains(key) ? keys : keys + [key]
}

/// Detaching removes the key, but the last attached issue always stays.
func removingKey(_ keys: [String], _ key: String) -> [String] {
    keys.count > 1 ? keys.filter { $0 != key } : keys
}

/// Every attached issue's sub-issues, in attach order, each sub-issue once (the mirror behind `plan/subtasks`).
func unionSubIssues(_ perIssue: [(key: String, children: [LinearSubIssue])]) -> [LinearSubIssue] {
    var seen = Set<String>()
    return perIssue.flatMap(\.children).filter { seen.insert($0.key).inserted }
}

/// Plan approval from Linear when ANY attached issue moves into a started state (see `shouldApproveFromLinear`).
func shouldApproveFromAny(
    stage: String?,
    approvedAtPresent: Bool,
    transitions: [(last: String?, current: String)],
    hasSpecDoc: Bool,
    hasSubIssues: Bool
) -> Bool {
    transitions.contains {
        shouldApproveFromLinear(
            stage: stage, approvedAtPresent: approvedAtPresent, lastStateType: $0.last,
            currentStateType: $0.current, hasSpecDoc: hasSpecDoc, hasSubIssues: hasSubIssues
        )
    }
}

/// The tabs Issue Details shows: attached issues in order, then temporary (not attached) ones, each once.
func displayedKeys(attached: [String], temporary: [String]) -> [String] {
    var seen = Set<String>()
    return (attached + temporary).filter { seen.insert($0).inserted }
}

enum IssueLinkAction: Equatable { case select, openTemporary }

/// What Open Link handing Issue Details an issue URL does: select the tab of an attached issue, else open a
/// temporary tab and ask whether to attach it.
func issueLinkAction(key: String, attached: [String], temporary: [String]) -> IssueLinkAction {
    attached.contains(key) ? .select : .openTemporary
}

enum TabCloseAction: Equatable { case refuse, confirmDetach, dropTemporary }

/// What closing `key`'s tab does: nothing for the last attached issue, a confirmation for another attached
/// one, and a plain close for a temporary tab.
func canClose(key: String, attached: [String]) -> TabCloseAction {
    guard attached.contains(key) else { return .dropTemporary }
    return attached.count > 1 ? .confirmDetach : .refuse
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
    /// The issue's state color in Linear, as sent; check with `validHexColor`.
    var stateColor: String? = nil
    var teamKey: String
    var states: [LinearState]
    var children: [LinearSubIssue]
    /// Every comment and reply on the issue, its sub-issues and its spec / testing documents,
    /// oldest first (the relay's input).
    var comments: [LinearComment] = []
}

/// One Linear comment (or reply). `quotedText` is set for an inline comment on a document.
struct LinearComment: Equatable, Sendable {
    var id: String
    var url: String
    var author: String
    var body: String
    var quotedText: String?
    var createdAt: String
}

/// The GraphQL document the sync agent runs once per poll: the issue, its team's workflow
/// states (with colors), its sub-issues, and every comment the relay needs (issue, sub-issues,
/// and the spec / testing documents, each optional via `@include`). `children(first: 100)` is
/// the documented cap.
let linearIssueQuery = """
query($id: String!, $spec: String!, $hasSpec: Boolean!, $testing: String!, $hasTesting: Boolean!) { \
issue(id: $id) { id identifier url title \
state { name type color } \
team { key states { nodes { name type position color } } } \
children(first: 100) { nodes { identifier title description state { name type } \
comments(first: 20) { nodes { id body url createdAt quotedText user { name } children(first: 20) { nodes { id body url createdAt user { name } } } } } } } \
comments(first: 50) { nodes { id body url createdAt quotedText user { name } children(first: 20) { nodes { id body url createdAt user { name } } } } } } \
spec: document(id: $spec) @include(if: $hasSpec) { comments(first: 50) { nodes { id body url createdAt quotedText user { name } children(first: 20) { nodes { id body url createdAt user { name } } } } } } \
testing: document(id: $testing) @include(if: $hasTesting) { comments(first: 50) { nodes { id body url createdAt quotedText user { name } children(first: 20) { nodes { id body url createdAt user { name } } } } } } }
"""

/// The `--variables-json` for `linearIssueQuery`. A nil/empty slug turns that document's
/// lookup off (`@include`) so an absent document is never queried.
func linearIssueVariablesJSON(key: String, specSlug: String?, testingSlug: String?) -> String {
    let spec = specSlug ?? ""
    let testing = testingSlug ?? ""
    let object: [String: Any] = [
        "id": key, "spec": spec, "hasSpec": !spec.isEmpty, "testing": testing, "hasTesting": !testing.isEmpty,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else { return "{}" }
    return json
}

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
        return LinearState(name: name, type: type, position: (node["position"] as? Double) ?? 0,
                           color: node["color"] as? String)
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
    // Comments: the issue, each sub-issue, and the spec / testing documents (siblings of
    // `issue` under `data`), with replies flattened in.
    let dataObject = root["data"] as? [String: Any]
    var commentNodes: [[String: Any]] = (issue["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    for node in childNodes {
        commentNodes += (node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    }
    for alias in ["spec", "testing"] {
        let doc = dataObject?[alias] as? [String: Any]
        commentNodes += (doc?["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    }
    let comments = flattenComments(commentNodes)
    return LinearIssuePayload(
        id: id, key: key, url: url, title: (issue["title"] as? String) ?? "",
        stateName: stateName, stateType: stateType, stateColor: state["color"] as? String,
        teamKey: teamKey, states: states, children: children, comments: comments
    )
}

private func flattenComments(_ nodes: [[String: Any]]) -> [LinearComment] {
    var out: [LinearComment] = []
    var seen = Set<String>()
    func visit(_ node: [String: Any]) {
        if let id = node["id"] as? String, !seen.contains(id) {
            seen.insert(id)
            let quoted = (node["quotedText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(LinearComment(
                id: id,
                url: (node["url"] as? String) ?? "",
                author: ((node["user"] as? [String: Any])?["name"] as? String) ?? "",
                body: (node["body"] as? String) ?? "",
                quotedText: quoted,
                createdAt: (node["createdAt"] as? String) ?? ""
            ))
        }
        for reply in (node["children"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] { visit(reply) }
    }
    nodes.forEach(visit)
    return out.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
}

// MARK: - State colors

/// `value` only when it is exactly `#RRGGBB` (what the host's `brandColorHex` accepts); anything
/// else (nil, short hex, a missing `#`, alpha, whitespace) is nil, so the chip stays neutral
/// instead of rendering garbage.
func validHexColor(_ value: String?) -> String? {
    guard let value, value.count == 7, value.hasPrefix("#"),
          value.dropFirst().allSatisfy(\.isHexDigit)
    else { return nil }
    return value
}

/// The color the status chip is filled with: the displayed state's own color from the team's
/// states (the agent may have just moved the issue, so the issue's own state can be stale), else
/// the issue's color when it is still in that state; nil means a neutral chip.
func displayStateColor(for issue: LinearIssuePayload, stateName: String) -> String? {
    if let color = issue.states.first(where: { $0.name == stateName })?.color {
        return validHexColor(color)
    }
    return stateName == issue.stateName ? validHexColor(issue.stateColor) : nil
}

// MARK: - Comment relay

/// Everything Work42 posts to Linear ends with this line, so the relay can tell those from a
/// person's comments (the API key posts as the user, so the author can't).
let work42CommentFooter = "_Posted from Work42_"

func isPostedFromWork42(_ body: String) -> Bool {
    body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(work42CommentFooter)
}

func withWork42Footer(_ body: String) -> String {
    isPostedFromWork42(body) ? body : body + "\n\n" + work42CommentFooter
}

/// Comments not yet relayed and not posted by Work42, oldest first.
func newComments(_ all: [LinearComment], seen: Set<String>) -> [LinearComment] {
    all.filter { !seen.contains($0.id) && !isPostedFromWork42($0.body) }
        .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
}

/// "<author> left you a comment on Linear <url>", then the quoted selection (inline comments
/// on a document) as a blockquote, then the comment.
func commentEventText(_ comment: LinearComment) -> String {
    let author = comment.author.isEmpty ? "Someone" : comment.author
    var text = "\(author) left you a comment on Linear \(comment.url)\n\n"
    if let quoted = comment.quotedText, !quoted.isEmpty {
        text += quoted.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
    }
    return text + comment.body
}

/// The shell line that posts a system event into the session (deduped by fingerprint).
func eventPostCommand(sessionId: String, fingerprint: String, message: String) -> String {
    "work42 event post --session \(shellQuote(sessionId)) --fingerprint \(shellQuote(fingerprint)) \(shellQuote(message))"
}

// MARK: - Session scoping

/// The host starts a widget's background agent in every session where the widget is
/// *available*, not only where it is placed in the layout, so the sync agent must
/// scope itself. It does nothing unless the session is of this type.
let linearSessionTypeID = "linear-task"

/// Whether the bound issue may DRIVE the session: mirror its sub-issues into `plan/subtasks`, read
/// approval back, push the stage to Linear, relay comments. Only `linear-task` sessions.
func shouldSync(typeId: String?) -> Bool {
    typeId == linearSessionTypeID
}

/// Whether a bound issue's labels (key, status, sub-issue count) show in the header. Any session whose
/// type is known: you added the widget and bound the issue there, so you opted in. Unknown (the read
/// failed, or Home, which has no session) stays idle. Showing writes nothing outside `linear/`.
func canDisplay(typeId: String?) -> Bool {
    typeId != nil
}

/// Reads `type_id` from `work42 session show --session <id> --json`
/// (`{"id","name","stage","type_id","workspace_id"}`).
func parseSessionTypeId(_ data: Data) -> String? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let typeId = object["type_id"] as? String, !typeId.isEmpty
    else { return nil }
    return typeId
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
