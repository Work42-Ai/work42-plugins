// Standalone logic tests for linear42's pure helpers. Run:
//   linear42/Tests/LogicTests/run.sh
// Compiles the Foundation-only widget sources together with this file.

import CoreGraphics
import Foundation
import ImageIO

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

// MARK: - link patterns (each widget's jurisdiction)

func claims(_ pattern: String, _ url: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    return regex.firstMatch(in: url, range: NSRange(url.startIndex..<url.endIndex, in: url)) != nil
}
let issuePage = "https://linear.app/work42/issue/WOR-6/linear-native-task-flow"
let specDoc = "https://linear.app/work42/document/spec-2838a00c306b"
let testingDoc = "https://linear.app/work42/document/testing-plan-9f3c1e7a4b2d"
check(claims(linearIssueLinkPattern, issuePage), "issue page is claimed by Issue Details")
check(claims(linearIssueLinkPattern, "https://linear.app/work42/issue/wor-7"), "issue key is case-insensitive")
check(claims(linearIssueLinkPattern, "https://linear.app/work42/issue/WOR-6#comment-1"), "issue URL with fragment")
check(!claims(linearIssueLinkPattern, specDoc), "a document is not an issue")
check(!claims(linearIssueLinkPattern, "https://linear.app/work42/team/WOR/all"), "a team page is not an issue")
check(!claims(linearIssueLinkPattern, "https://example.com/work42/issue/WOR-6"), "other hosts aren't claimed")
check(claims(linearSpecDocLinkPattern, specDoc), "spec document is claimed by Spec Document")
check(claims(linearSpecDocLinkPattern, specDoc + "#comment-abc"), "spec document with fragment")
check(!claims(linearSpecDocLinkPattern, testingDoc), "the testing plan is not the spec")
check(!claims(linearSpecDocLinkPattern, issuePage), "an issue is not the spec")
check(claims(linearTestingDocLinkPattern, testingDoc), "testing plan is claimed by Testing Plan Document")
check(!claims(linearTestingDocLinkPattern, specDoc), "the spec is not the testing plan")
check(linkDestination(URL(string: specDoc)!, current: URL(string: specDoc)) == nil, "the page already shown needs no navigation")
check(linkDestination(URL(string: specDoc)!, current: URL(string: testingDoc)) == URL(string: specDoc), "a different page is navigated to")
check(linkDestination(URL(string: specDoc)!, current: nil) == URL(string: specDoc), "no stored page: navigate")

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

// MARK: - Linear branding (AC31, AC32)

check(validHexColor("#5e6ad2") == "#5e6ad2", "a lower-case hex color is valid")
check(validHexColor("#F2C94C") == "#F2C94C", "an upper-case hex color is valid")
check(validHexColor(nil) == nil, "nil has no color")
check(validHexColor("") == nil, "empty is not a color")
check(validHexColor("#fff") == nil, "short hex is rejected (the host wants #RRGGBB)")
check(validHexColor("5e6ad2") == nil, "a missing # is rejected")
check(validHexColor("#12345g") == nil, "a non-hex digit is rejected")
check(validHexColor("#5e6ad2ff") == nil, "alpha hex is rejected")
check(validHexColor(" #5e6ad2") == nil, "surrounding whitespace is rejected")

check(linearIssueQuery.contains("state { name type color }"), "the issue's state color is requested")
check(linearIssueQuery.contains("states { nodes { name type position color } }"), "every team state's color is requested")

let colorPayloadJSON = #"""
{"data":{"issue":{"id":"u","identifier":"WOR-6","url":"https://linear.app/x","title":"T",
"state":{"name":"In Progress","type":"started","color":"#f2c94c"},
"team":{"key":"WOR","states":{"nodes":[
 {"name":"Todo","type":"unstarted","position":1,"color":"#e2e2e2"},
 {"name":"In Progress","type":"started","position":2,"color":"#f2c94c"},
 {"name":"In Review","type":"started","position":3,"color":"#0f783c"},
 {"name":"Odd","type":"backlog","position":4,"color":"not-a-color"},
 {"name":"NoColor","type":"backlog","position":5}]}}}}}
"""#
if let cp = parseIssuePayload(Data(colorPayloadJSON.utf8)) {
    check(cp.stateColor == "#f2c94c", "the issue's state color is decoded")
    check(cp.states.map(\.color) == ["#e2e2e2", "#f2c94c", "#0f783c", "not-a-color", nil], "team state colors are decoded as sent")
    check(displayStateColor(for: cp, stateName: "In Progress") == "#f2c94c", "the displayed state's own color")
    check(displayStateColor(for: cp, stateName: "In Review") == "#0f783c", "a state the agent moved the issue to uses ITS color, not the old one")
    check(displayStateColor(for: cp, stateName: "Odd") == nil, "an invalid color falls back to neutral")
    check(displayStateColor(for: cp, stateName: "NoColor") == nil, "a state without a color is neutral")
    check(displayStateColor(for: cp, stateName: "Nope") == nil, "an unknown state name is neutral")
} else { check(false, "color payload parses") }
if let plain = parseIssuePayload(Data(payloadJSON.utf8)) {
    check(plain.stateColor == nil && plain.states.allSatisfy { $0.color == nil }, "a payload without colors decodes with none")
    check(displayStateColor(for: plain, stateName: "In Progress") == nil, "no colors means neutral chips")
}

func pngHeader(_ data: Data?) -> (width: Int, height: Int, colorType: UInt8)? {
    guard let d = data, d.count > 26, Array(d.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
    func be32(_ at: Int) -> Int { (Int(d[at]) << 24) | (Int(d[at + 1]) << 16) | (Int(d[at + 2]) << 8) | Int(d[at + 3]) }
    return (be32(16), be32(20), d[25])
}
check(pngHeader(linearIconPNG).map { $0.width == 64 && $0.height == 64 } == true, "the Linear icon is a 64x64 PNG")
check(pngHeader(linearMarkPNG).map { $0.width == 64 && $0.height == 64 } == true, "the Linear mark is a 64x64 PNG")
check(pngHeader(linearMarkPNG)?.colorType == 6, "the mark carries an alpha channel, so the host can tint it on the brand fill")
check(linearIconPNG != linearMarkPNG, "the colored icon and the tintable mark are different images")

/// Mean color of the solid pixels (alpha >= 250) and the share of the image they cover.
func solidPixelStats(_ data: Data?) -> (r: Double, g: Double, b: Double, coverage: Double)? {
    guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(
        data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var count = 0.0, r = 0.0, g = 0.0, b = 0.0
    for i in stride(from: 0, to: buffer.count, by: 4) where buffer[i + 3] >= 250 {
        count += 1; r += Double(buffer[i]); g += Double(buffer[i + 1]); b += Double(buffer[i + 2])
    }
    guard count > 0 else { return (0, 0, 0, 0) }
    return (r / count, g / count, b / count, count / Double(w * h))
}
if let icon = solidPixelStats(linearIconPNG) {
    // Linear purple #5E6AD2 = (94, 106, 210): the icon is colored, so it reads on light AND dark UI.
    check(abs(icon.r - 94) < 8 && abs(icon.g - 106) < 8 && abs(icon.b - 210) < 8, "the icon's visible pixels are Linear purple (got \(Int(icon.r)),\(Int(icon.g)),\(Int(icon.b)))")
    check(icon.coverage > 0.3, "the icon is a real mark, not a sliver (covers \(Int(icon.coverage * 100))% of the image)")
} else { check(false, "the Linear icon decodes") }
check(linearBrandHex == "#5E6AD2", "Linear's brand purple")

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
// A bound issue's labels show in any session type (you put the widget there); only linear-task sessions
// let the issue drive the session (subtask mirror, approval, stage push, comments).
check(canDisplay(typeId: "linear-task"), "canDisplay: linear-task shows labels")
check(canDisplay(typeId: "task"), "canDisplay: a task42 session with a bound issue still shows labels")
check(canDisplay(typeId: "chat"), "canDisplay: a chat session with a bound issue shows labels")
check(!canDisplay(typeId: nil), "canDisplay: unknown type (read failed, Home) stays idle")
check(shouldSync(typeId: "linear-task") && !shouldSync(typeId: "task") && !shouldSync(typeId: "chat"), "only linear-task sessions are driven by the issue")
check(parseSessionTypeId(Data(#"{"id":"b0c6","name":"x","stage":"Planning","type_id":"task","workspace_id":"w"}"#.utf8)) == "task", "parseSessionTypeId: reads the real `session show` shape")
check(parseSessionTypeId(Data(#"{"type_id":"linear-task"}"#.utf8)) == "linear-task", "parseSessionTypeId: linear-task")
check(parseSessionTypeId(Data("{}".utf8)) == nil, "parseSessionTypeId: missing field is nil")
check(parseSessionTypeId(Data(#"{"type_id":""}"#.utf8)) == nil, "parseSessionTypeId: empty is nil")
check(parseSessionTypeId(Data("not json".utf8)) == nil, "parseSessionTypeId: invalid JSON is nil")
check(parseSessionTypeId(Data(#"{"type_id":7}"#.utf8)) == nil, "parseSessionTypeId: wrong type is nil")

// MARK: - several issues per session (AC50-AC53)

check(issueAddress("WOR-6", "spec_doc") == "linear/issues/WOR-6/spec_doc", "per-issue address")
check(issueAddress("WOR-7", "issue") == "linear/issues/WOR-7/issue", "per-issue address, another issue")

// AC51: flat keys migrate under the bound issue, copy then index then delete.
let fullFlat = flatMigrationPlan(
    issueKey: "WOR-6",
    presentFlat: ["issue", "spec_doc", "testing_doc", "last_state_type", "pushed_stage"],
    hasIndex: false
)
check(fullFlat?.copies.map(\.from) == ["linear/issue", "linear/spec_doc", "linear/testing_doc", "linear/last_state_type", "linear/pushed_stage"], "migration copies every flat key present, in order")
check(fullFlat?.copies.map(\.to) == ["linear/issues/WOR-6/issue", "linear/issues/WOR-6/spec_doc", "linear/issues/WOR-6/testing_doc", "linear/issues/WOR-6/last_state_type", "linear/issues/WOR-6/pushed_stage"], "migration copies to the per-issue keys")
check(fullFlat?.keys == ["WOR-6"], "migration writes linear/issue_keys = [KEY]")
check(fullFlat?.deletes == ["linear/issue", "linear/spec_doc", "linear/testing_doc", "linear/last_state_type", "linear/pushed_stage"], "migration deletes the flat keys it copied")
let partialFlat = flatMigrationPlan(issueKey: "WOR-6", presentFlat: ["issue", "last_state_type"], hasIndex: false)
check(partialFlat?.copies.count == 2 && partialFlat?.deletes == ["linear/issue", "linear/last_state_type"], "migration only touches the flat keys present")
check(flatMigrationPlan(issueKey: "WOR-6", presentFlat: ["issue", "spec_doc"], hasIndex: true) == nil, "no migration once linear/issue_keys exists")
check(flatMigrationPlan(issueKey: "WOR-6", presentFlat: [], hasIndex: false) == nil, "no migration with no flat keys")
check(flatMigrationPlan(issueKey: nil, presentFlat: ["spec_doc"], hasIndex: false) == nil, "no migration without a resolved flat issue to name the scope")

// Attached keys.
check(appendingKey(["WOR-6"], "WOR-7") == ["WOR-6", "WOR-7"], "append a new key last")
check(appendingKey(["WOR-6", "WOR-7"], "WOR-6") == ["WOR-6", "WOR-7"], "an attached key is not added twice")
check(parseKeyList(["WOR-6", "wor-7", 3, "bad"] as [Any]) == ["WOR-6", "WOR-7"], "key list keeps valid keys, normalised, in order")
check(parseKeyList(nil).isEmpty && parseKeyList("WOR-6").isEmpty, "a missing or non-array key list is empty")
check(removingKey(["WOR-6", "WOR-7"], "WOR-7") == ["WOR-6"], "detach removes the key")
check(removingKey(["WOR-6"], "WOR-6") == ["WOR-6"], "the last issue cannot be detached")

// AC53: sub-issues of every attached issue, in key order, one row per sub-issue.
func sub(_ key: String, done: Bool = false) -> LinearSubIssue {
    LinearSubIssue(key: key, title: key, description: "", stateName: done ? "Done" : "Todo", stateType: done ? "completed" : "unstarted")
}
let union = unionSubIssues([("WOR-6", [sub("WOR-8"), sub("WOR-9", done: true)]), ("WOR-7", [sub("WOR-30"), sub("WOR-8")])])
check(union.map(\.key) == ["WOR-8", "WOR-9", "WOR-30"], "union keeps key order and drops a repeated sub-issue")
check(unionSubIssues([]).isEmpty, "no issues, no sub-issues")

// AC53: any attached issue moving into started approves.
check(shouldApproveFromAny(stage: "Planning", approvedAtPresent: false,
                           transitions: [(last: "started", current: "started"), (last: "unstarted", current: "started")],
                           hasSpecDoc: true, hasSubIssues: true), "the second issue moving to started approves")
check(!shouldApproveFromAny(stage: "Planning", approvedAtPresent: false,
                            transitions: [(last: "started", current: "started"), (last: nil, current: "started")],
                            hasSpecDoc: true, hasSubIssues: true), "a newly attached issue already started is not an approval")
check(!shouldApproveFromAny(stage: "In-Progress", approvedAtPresent: false,
                            transitions: [(last: "unstarted", current: "started")],
                            hasSpecDoc: true, hasSubIssues: true), "only while Planning")
check(!shouldApproveFromAny(stage: "Planning", approvedAtPresent: false, transitions: [],
                            hasSpecDoc: true, hasSubIssues: true), "no issues, no approval")

// Issue Details tabs (AC54): attached issues first, then temporary ones not attached.
check(displayedKeys(attached: ["WOR-6", "WOR-7"], temporary: ["WOR-9"]) == ["WOR-6", "WOR-7", "WOR-9"], "attached then temporary")
check(displayedKeys(attached: ["WOR-6"], temporary: ["WOR-6", "WOR-9", "WOR-9"]) == ["WOR-6", "WOR-9"], "a temporary tab that got attached, or repeated, shows once")
check(issueLinkAction(key: "WOR-7", attached: ["WOR-6", "WOR-7"], temporary: []) == .select, "an attached issue just selects its tab")
check(issueLinkAction(key: "WOR-9", attached: ["WOR-6"], temporary: []) == .openTemporary, "an unattached issue opens a temporary tab with the attach question")
check(issueLinkAction(key: "WOR-9", attached: ["WOR-6"], temporary: ["WOR-9"]) == .openTemporary, "an already-open temporary tab asks again")
check(canClose(key: "WOR-6", attached: ["WOR-6"]) == .refuse, "the last attached issue's tab cannot be closed")
check(canClose(key: "WOR-7", attached: ["WOR-6", "WOR-7"]) == .confirmDetach, "closing an attached tab asks first")
check(canClose(key: "WOR-9", attached: ["WOR-6", "WOR-7"]) == .dropTemporary, "closing a temporary tab needs no confirmation")

// MARK: - linearCLIPathPrefix

check(linearCLIPathPrefix.contains("$HOME/.local/bin") && linearCLIPathPrefix.contains("$HOME/.cargo/bin"), "user-level install dirs are on the CLI PATH")
check(linearCLIPathPrefix.hasPrefix("export PATH=\"$PATH:"), "appended, so a Homebrew copy still wins")
check(linearCLIPathPrefix.hasSuffix("; "), "chains into the command that follows")

// MARK: - shellQuote

check(shellQuote("a b") == "'a b'", "plain")
check(shellQuote("it's") == #"'it'\''s'"#, "embedded single quote")

if failures == 0 { print("linear42 logic tests: all passed") } else { print("linear42 logic tests: \(failures) FAILED"); exit(1) }
