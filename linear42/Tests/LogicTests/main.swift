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

if failures == 0 { print("linear42 logic tests: all passed") } else { print("linear42 logic tests: \(failures) FAILED"); exit(1) }
