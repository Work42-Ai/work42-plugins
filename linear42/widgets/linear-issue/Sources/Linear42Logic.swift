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
