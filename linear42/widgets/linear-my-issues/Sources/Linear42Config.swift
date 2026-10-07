// Linear42Config.swift — the one config every linear42 widget reads.
//
// ~/.config/linear42/config.json, re-read on EVERY poll and action (never
// cached across cycles), so an edit takes effect without a restart:
//
//   {
//     "workspace": "work42",           // required — the linear.app URL key
//     "default_team": "WOR",           // required — team for Planner-created issues
//     "poll_seconds": 60,              // optional — default 60, minimum 15
//     "stage_states": {                // optional — per-team stage -> exact state name
//       "WOR": { "Human Review": "In Review" }
//     }
//   }
//
// Foundation-only so it can be compiled and tested standalone
// (linear42/Tests/LogicTests). This file is duplicated verbatim into each
// widget that needs it — widgets compile independently and cannot share a module.

import Foundation

struct Linear42Config: Equatable, Sendable {
    var workspace: String
    var defaultTeam: String
    var pollSeconds: Int
    var stageStates: [String: [String: String]]

    static let defaultPollSeconds = 60
    static let minimumPollSeconds = 15

    enum LoadError: Error, Equatable, Sendable {
        case missingFile(path: String)
        case invalidJSON
        case missingField(String)

        /// Human-readable reason, shown in the "linear42 isn't configured" notice.
        var message: String {
            switch self {
            case .missingFile(let path): return "missing file \(path)"
            case .invalidJSON: return "the file is not valid JSON"
            case .missingField(let name): return "missing or empty field \"\(name)\""
            }
        }
    }

    /// `~/.config/linear42/config.json`.
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/linear42/config.json").path
    }

    /// Reads and parses the config file at `path` (fresh on every call).
    static func load(path: String = Linear42Config.defaultPath) -> Result<Linear42Config, LoadError> {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(.missingFile(path: path))
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> Result<Linear42Config, LoadError> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        func requiredString(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let workspace = requiredString("workspace") else { return .failure(.missingField("workspace")) }
        guard let team = requiredString("default_team") else { return .failure(.missingField("default_team")) }

        var poll = defaultPollSeconds
        if let n = object["poll_seconds"] as? Int { poll = max(n, minimumPollSeconds) }

        var stageStates: [String: [String: String]] = [:]
        if let raw = object["stage_states"] as? [String: Any] {
            for (teamKey, value) in raw {
                guard let perStage = value as? [String: Any] else { continue }
                let names = perStage.compactMapValues { $0 as? String }.filter { !$0.value.isEmpty }
                if !names.isEmpty { stageStates[teamKey] = names }
            }
        }
        return .success(Linear42Config(
            workspace: workspace, defaultTeam: team, pollSeconds: poll, stageStates: stageStates
        ))
    }
}
