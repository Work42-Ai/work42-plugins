// Standalone logic tests for linear42's pure helpers. Run:
//   linear42/Tests/LogicTests/run.sh
// Compiles the Foundation-only widget sources together with this file.

import Foundation

nonisolated(unsafe) var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL (line \(line)): \(what)") }
}

// MARK: - linearIssueKey

check(linearIssueKey(from: "WOR-123") == "WOR-123", "bare key")
check(linearIssueKey(from: "  wor-7 \n") == "WOR-7", "bare key is trimmed and upper-cased")
check(linearIssueKey(from: "https://linear.app/work42/issue/WOR-123/some-slug") == "WOR-123", "issue URL with slug")
check(linearIssueKey(from: "https://linear.app/work42/issue/wor-9") == "WOR-9", "issue URL, lower-case key")
check(linearIssueKey(from: "https://linear.app/work42/team/WOR/all") == nil, "team URL has no issue key")
check(linearIssueKey(from: "https://example.com/issue/WOR-1") == nil, "non-linear host rejected")
check(linearIssueKey(from: "") == nil, "empty")
check(linearIssueKey(from: "WOR") == nil, "no number")
check(linearIssueKey(from: "WOR-") == nil, "empty number")
check(linearIssueKey(from: "123-4") == nil, "team must start with a letter")
check(linearIssueKey(from: "WOR-12a") == nil, "number must be digits")

// MARK: - linearIssueURL

check(linearIssueURL(workspace: "work42", key: "WOR-1") == "https://linear.app/work42/issue/WOR-1", "canonical URL")
check(linearIssueURL(workspace: "my ws", key: "A-1") == "https://linear.app/my%20ws/issue/A-1", "workspace is path-encoded")

// MARK: - Linear42Config.parse

func parse(_ json: String) -> Result<Linear42Config, Linear42Config.LoadError> {
    Linear42Config.parse(Data(json.utf8))
}
if case .success(let c) = parse(#"{"workspace":"work42","default_team":"WOR"}"#) {
    check(c.workspace == "work42" && c.defaultTeam == "WOR", "required fields")
    check(c.pollSeconds == 60, "default poll")
    check(c.stageStates.isEmpty, "default stage_states")
} else { check(false, "minimal config parses") }

if case .success(let c) = parse(#"{"workspace":"w","default_team":"T","poll_seconds":5}"#) {
    check(c.pollSeconds == 15, "poll_seconds clamps to the 15s minimum")
} else { check(false, "poll clamp config parses") }

if case .success(let c) = parse(#"{"workspace":"w","default_team":"T","poll_seconds":120,"stage_states":{"WOR":{"Human Review":"In Review","Testing":""},"BAD":5}}"#) {
    check(c.pollSeconds == 120, "poll_seconds honoured")
    check(c.stageStates == ["WOR": ["Human Review": "In Review"]], "empty names and non-object teams are dropped")
} else { check(false, "stage_states config parses") }

check(parse("not json") == .failure(.invalidJSON), "invalid JSON")
check(parse("[1,2]") == .failure(.invalidJSON), "non-object JSON")
check(parse(#"{"default_team":"WOR"}"#) == .failure(.missingField("workspace")), "missing workspace")
check(parse(#"{"workspace":"  ","default_team":"WOR"}"#) == .failure(.missingField("workspace")), "blank workspace")
check(parse(#"{"workspace":"w"}"#) == .failure(.missingField("default_team")), "missing default_team")
check(parse(#"{"workspace":"w","default_team":7}"#) == .failure(.missingField("default_team")), "non-string default_team")

let missing = Linear42Config.load(path: "/nonexistent/linear42/config.json")
check(missing == .failure(.missingFile(path: "/nonexistent/linear42/config.json")), "missing file")
check(Linear42Config.LoadError.missingField("workspace").message.contains("workspace"), "message names the field")

// MARK: - resolveStageState

let teamStates = [
    LinearState(name: "Backlog", type: "backlog", position: 0),
    LinearState(name: "Todo", type: "unstarted", position: 1),
    LinearState(name: "Ready", type: "unstarted", position: 0.5),
    LinearState(name: "In Progress", type: "started", position: 2),
    LinearState(name: "In Review", type: "started", position: 3),
    LinearState(name: "Done", type: "completed", position: 4),
    LinearState(name: "Canceled", type: "canceled", position: 5),
]
func resolve(_ stage: String, _ overrides: [String: [String: String]] = [:], states: [LinearState] = teamStates) -> StageStateResolution {
    resolveStageState(stage: stage, teamKey: "WOR", states: states, stageStates: overrides)
}
check(resolve("Planning") == .move("Ready"), "Planning -> lowest-position unstarted")
check(resolve("In-Progress") == .move("In Progress"), "In-Progress -> lowest-position started")
check(resolve("Testing") == .move("In Progress"), "Testing -> started")
check(resolve("Human Review") == .move("In Review"), "Human Review -> started state named *review*")
check(resolve("Done") == .move("Done"), "Done -> completed")
check(resolve("Bogus") == .skip, "unmapped stage skips")
let noReview = teamStates.filter { $0.name != "In Review" }
check(resolve("Human Review", states: noReview) == .skip, "no review state -> skip, never In Progress")
check(resolve("Done", states: teamStates.filter { $0.type != "completed" }) == .skip, "no completed state -> skip")
check(resolve("Human Review", ["WOR": ["Human Review": "In Progress"]]) == .move("In Progress"), "override pins an exact state")
check(resolve("Testing", ["wor": ["Testing": "QA"]]) == .missingOverride("QA"), "override naming a missing state; team key is case-insensitive")
check(resolve("Planning", ["OTHER": ["Planning": "Backlog"]]) == .move("Ready"), "another team's override is ignored")
check(resolve("Planning", [:], states: []) == .skip, "no states at all")

// MARK: - shouldApproveFromLinear

func approve(stage: String? = "Planning", approved: Bool = false, last: String? = "unstarted",
             current: String = "started", spec: Bool = true, subs: Bool = true) -> Bool {
    shouldApproveFromLinear(stage: stage, approvedAtPresent: approved, lastStateType: last,
                            currentStateType: current, hasSpecDoc: spec, hasSubIssues: subs)
}
check(approve(), "unstarted -> started in Planning with spec + sub-issues approves")
check(!approve(last: nil), "first observation never approves (binding an in-progress issue)")
check(!approve(last: "started"), "already started is not a change")
check(!approve(current: "completed"), "only a move INTO started counts")
check(!approve(stage: "In-Progress"), "only while Planning")
check(!approve(stage: nil), "unknown stage")
check(!approve(approved: true), "already approved")
check(!approve(spec: false), "needs a spec doc")
check(!approve(subs: false), "needs a sub-issue")

// MARK: - parseIssuePayload

let payloadJSON = #"""
{"data":{"issue":{"id":"uuid-1","identifier":"WOR-12","url":"https://linear.app/work42/issue/WOR-12/x","title":"T",
"state":{"name":"In Progress","type":"started"},
"team":{"key":"WOR","states":{"nodes":[{"name":"Todo","type":"unstarted","position":1},{"name":"Done","type":"completed","position":4.5}]}},
"children":{"nodes":[
 {"identifier":"WOR-13","title":"a","description":"do a","state":{"name":"Done","type":"completed"}},
 {"identifier":"WOR-14","title":"b","description":null,"state":{"name":"Canceled","type":"canceled"}},
 {"identifier":"WOR-15","title":"c","description":"do c","state":{"name":"Todo","type":"unstarted"}},
 {"title":"no identifier","state":{"name":"Todo","type":"unstarted"}}]}}}}
"""#
if let p = parseIssuePayload(Data(payloadJSON.utf8)) {
    check(p.key == "WOR-12" && p.teamKey == "WOR" && p.stateType == "started", "issue fields")
    check(p.states == [LinearState(name: "Todo", type: "unstarted", position: 1),
                       LinearState(name: "Done", type: "completed", position: 4.5)], "team states")
    check(p.children.count == 3, "children without an identifier are dropped")
    check(p.children.map(\.done) == [true, false, false], "only a completed state is done (canceled is not)")
    check(p.children[1].description == "", "null description reads as empty")
} else { check(false, "payload parses") }
check(parseIssuePayload(Data(#"{"data":{"issue":null}}"#.utf8)) == nil, "null issue is a failed poll")
check(parseIssuePayload(Data(#"{"errors":[{"message":"x"}]}"#.utf8)) == nil, "error envelope")
check(parseIssuePayload(Data("nope".utf8)) == nil, "garbage")

// MARK: - Linear comments relay (AC43/AC44)

check(linearIssueQuery.contains("comments(first: 50)") && linearIssueQuery.contains("quotedText"), "query asks for issue comments incl. the inline quote")
check(linearIssueQuery.contains("@include(if: $hasSpec)") && linearIssueQuery.contains("@include(if: $hasTesting)"), "document comments are optional via @include")
check(linearIssueQuery.contains("comments(first: 20)"), "query asks for sub-issue comments")

let varsAll = linearIssueVariablesJSON(key: "WOR-6", specSlug: "2838a00c306b", testingSlug: "aca05b5edd7b")
let varsObj = (try? JSONSerialization.jsonObject(with: Data(varsAll.utf8))) as? [String: Any] ?? [:]
check(varsObj["id"] as? String == "WOR-6" && varsObj["spec"] as? String == "2838a00c306b" && varsObj["hasSpec"] as? Bool == true, "variables carry the spec slug")
check(varsObj["testing"] as? String == "aca05b5edd7b" && varsObj["hasTesting"] as? Bool == true, "variables carry the testing slug")
let varsNone = (try? JSONSerialization.jsonObject(with: Data(linearIssueVariablesJSON(key: "WOR-6", specSlug: nil, testingSlug: "").utf8))) as? [String: Any] ?? [:]
check(varsNone["hasSpec"] as? Bool == false && varsNone["hasTesting"] as? Bool == false, "no slug (nil or empty) turns the document lookup off")

let commentsPayloadJSON = #"""
{"data":{
"issue":{"id":"uuid-1","identifier":"WOR-6","url":"https://linear.app/work42/issue/WOR-6/x","title":"T",
 "state":{"name":"Backlog","type":"backlog"},
 "team":{"key":"WOR","states":{"nodes":[]}},
 "comments":{"nodes":[
  {"id":"c2","body":"second on issue","url":"https://linear.app/c2","createdAt":"2026-10-07T02:00:00.000Z","quotedText":null,"user":{"name":"Yan"},
   "children":{"nodes":[{"id":"c3","body":"a reply","url":"https://linear.app/c3","createdAt":"2026-10-07T02:30:00.000Z","user":{"name":"Sam"}}]}}]},
 "children":{"nodes":[
  {"identifier":"WOR-7","title":"a","description":"d","state":{"name":"Done","type":"completed"},
   "comments":{"nodes":[{"id":"c1","body":"on a sub-issue","url":"https://linear.app/c1","createdAt":"2026-10-07T01:00:00.000Z","user":{"name":"Yan"}}]}}]}},
"spec":{"comments":{"nodes":[
  {"id":"c4","body":"inline on spec","url":"https://linear.app/c4","createdAt":"2026-10-07T03:00:00.000Z","quotedText":"THE SYSTEM SHALL","user":{"name":"Yan"},"children":{"nodes":[]}}]}},
"testing":null}}
"""#
if let cp = parseIssuePayload(Data(commentsPayloadJSON.utf8)) {
    check(cp.comments.map(\.id) == ["c1", "c2", "c3", "c4"], "comments from issue, replies, sub-issues and spec doc, oldest first")
    check(cp.comments.first { $0.id == "c4" }?.quotedText == "THE SYSTEM SHALL", "inline quote is kept")
    check(cp.comments.first { $0.id == "c3" }?.author == "Sam", "reply author")
    check(cp.comments.first { $0.id == "c2" }?.quotedText == nil, "null quote reads as nil")
} else { check(false, "comments payload parses") }
if let plain = parseIssuePayload(Data(payloadJSON.utf8)) { check(plain.comments.isEmpty, "a payload without comment fields has none") }

func mk(_ id: String, _ body: String, at t: String = "2026-10-07T00:00:00.000Z", quote: String? = nil) -> LinearComment {
    LinearComment(id: id, url: "https://linear.app/\(id)", author: "Yan", body: body, quotedText: quote, createdAt: t)
}
check(newComments([mk("a", "x"), mk("b", "y")], seen: ["a"]).map(\.id) == ["b"], "seen ids are dropped")
check(newComments([mk("late", "x", at: "2026-10-07T05:00:00.000Z"), mk("early", "y", at: "2026-10-07T01:00:00.000Z")], seen: []).map(\.id) == ["early", "late"], "oldest first")
check(newComments([mk("o", "stamp\n\n_Posted from Work42_"), mk("h", "human")], seen: []).map(\.id) == ["h"], "comments Work42 posted are skipped")
check(newComments([mk("o", "stamp\n\n_Posted from Work42_\n")], seen: []).isEmpty, "footer with trailing newline still counts")
check(isPostedFromWork42("body\n\n_Posted from Work42_") && !isPostedFromWork42("quoting _Posted from Work42_ mid-text"), "footer must end the comment")
check(withWork42Footer("hello") == "hello\n\n_Posted from Work42_", "footer appended")
check(withWork42Footer(withWork42Footer("hello")) == "hello\n\n_Posted from Work42_", "footer is idempotent")

check(commentEventText(mk("c1", "please change this")) == "Yan left you a comment on Linear https://linear.app/c1\n\nplease change this", "event text without a quote")
check(commentEventText(mk("c4", "fix it", quote: "line one\nline two")) == "Yan left you a comment on Linear https://linear.app/c4\n\n> line one\n> line two\n\nfix it", "event text quotes inline selections")
check(commentEventText(LinearComment(id: "z", url: "u", author: "", body: "b", quotedText: nil, createdAt: "")) == "Someone left you a comment on Linear u\n\nb", "missing author falls back")

check(eventPostCommand(sessionId: "s-1", fingerprint: "linear42-comment-c1", message: "it's here") == "work42 event post --session 's-1' --fingerprint 'linear42-comment-c1' 'it'\\''s here'", "event command is shell-quoted")

// MARK: - session scoping

check(shouldSync(typeId: "linear-task"), "shouldSync: linear-task sessions sync")
check(!shouldSync(typeId: "task"), "shouldSync: a task42 session does not")
check(!shouldSync(typeId: "chat"), "shouldSync: a chat session does not")
check(!shouldSync(typeId: nil), "shouldSync: unknown type (read not done or failed) does not")
check(parseSessionTypeId(Data(#"{"id":"b0c6","name":"x","stage":"Planning","type_id":"task","workspace_id":"w"}"#.utf8)) == "task", "parseSessionTypeId: reads the real `session show` shape")
check(parseSessionTypeId(Data(#"{"type_id":"linear-task"}"#.utf8)) == "linear-task", "parseSessionTypeId: linear-task")
check(parseSessionTypeId(Data("{}".utf8)) == nil, "parseSessionTypeId: missing field is nil")
check(parseSessionTypeId(Data(#"{"type_id":""}"#.utf8)) == nil, "parseSessionTypeId: empty is nil")
check(parseSessionTypeId(Data("not json".utf8)) == nil, "parseSessionTypeId: invalid JSON is nil")
check(parseSessionTypeId(Data(#"{"type_id":7}"#.utf8)) == nil, "parseSessionTypeId: wrong type is nil")

// MARK: - linearCLIPathPrefix

check(linearCLIPathPrefix.contains("$HOME/.local/bin") && linearCLIPathPrefix.contains("$HOME/.cargo/bin"), "user-level install dirs are on the CLI PATH")
check(linearCLIPathPrefix.hasPrefix("export PATH=\"$PATH:"), "appended, so a Homebrew copy still wins")
check(linearCLIPathPrefix.hasSuffix("; "), "chains into the command that follows")

// MARK: - shellQuote

check(shellQuote("a b") == "'a b'", "plain")
check(shellQuote("it's") == #"'it'\''s'"#, "embedded single quote")

if failures == 0 { print("linear42 logic tests: all passed") } else { print("linear42 logic tests: \(failures) FAILED"); exit(1) }
