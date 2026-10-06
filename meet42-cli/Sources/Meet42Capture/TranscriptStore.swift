// TranscriptStore.swift — Shared transcript parsing for meeting sessions.
//
// Extracted from TranscriptWidgetView (Work42App) so that both the app's
// real Transcript tile AND the menu's TranscriptMenuSurface call exactly
// the same parsing logic, preventing format/edge-case drift between them.
//
// Public API:
//   TranscriptLine          — one decoded line from conversation.jsonl
//   ResolvedSpeaker         — a speaker resolved from speakers.json
//   conversationPath(sessionDir:) → String
//   speakersPath(sessionDir:)     → String
//   parseConversation(sessionDir:) → [TranscriptLine]
//   loadSpeakers(sessionDir:)      → [String: ResolvedSpeaker]
//
// All functions are `nonisolated` free functions — safe to call from any
// actor context; none performs I/O on the main thread by default (Swift 6
// strict concurrency; callers are responsible for actor context).

import CoreGraphics
import Foundation

// MARK: - TranscriptLine

/// One decoded line from `conversation.jsonl`.
///
/// Two line shapes are supported (AC11 back-compat):
///
///   • **Speaker line** (legacy, no `type` field):
///     `{ "ts": "…", "speaker": "You"|"Them", "text": "…" }`
///     A missing `type` key => speaker line.  Decodes into `.speaker(SpeakerLine)`.
///
///   • **System-event line** (`type == "system_event"`):
///     `{ "ts": "…", "type": "system_event", "event": "screen_highlight",
///        "image": "…", "app": "…", "bundle_id": "…", "ocr_text": "…",
///        "rect": { "x": …, "y": …, "width": …, "height": … } }`
///     Decodes into `.systemEvent(SystemEventEntry)`.
///
/// A line that fails to decode is returned as `nil` and filtered out by
/// `parseConversation(sessionDir:)` (no crash, AC11).
public enum TranscriptLine: Identifiable, Sendable {

    // MARK: - Associated data

    public struct SpeakerLine: Sendable {
        public let id: UUID
        public let ts: String
        public let speaker: Speaker
        public let text: String
        /// Audio-timeline interval (seconds, relative to when this session's
        /// "Them"-channel transcription began) when these words were actually
        /// spoken — distinct from `ts`, which is the wall-clock moment the
        /// line FINALIZED (lags real speech by seconds). nil when the
        /// SpeechTranscriber result carried no `audioTimeRange` attribute
        /// (e.g. the "You" channel, or a result where Apple's framework
        /// didn't report timing — a known intermittent gap). Diarization
        /// correlation (speaker-label tagging) depends on these being
        /// present for "Them" lines; consumers must tolerate nil.
        public let audioStartSeconds: Double?
        public let audioEndSeconds: Double?
        /// Stable identifier minted by ConversationLog at append time
        /// (JSON key "lineId"). nil for lines written before this field
        /// existed. Pass to a rewrite/correction call to target this exact
        /// line.
        public let persistentId: String?
        /// Live or resolved diarization label for this line ("Voice A"/
        /// "Voice B"/... from SpeakerDiarizationService, a real name once
        /// the meeting-end attribution pass or a manual correction resolves
        /// it, or nil — falls back to the plain `speaker` field, i.e.
        /// today's "You"/"Them" behavior).
        public let speakerLabel: String?

        public enum Speaker: String, Sendable {
            case you  = "You"
            case them = "Them"
            case unknown
        }
    }

    public struct SystemEventEntry: Sendable {
        public let id: UUID
        public let ts: String
        public let event: String          // e.g. "screen_highlight"
        public let imagePath: String?     // relative path inside session dir
        public let appName: String?
        public let bundleId: String?
        public let ocrText: String?
        public let rect: CGRect?
    }

    case speaker(SpeakerLine)
    case systemEvent(SystemEventEntry)

    // MARK: - Identifiable

    public var id: UUID {
        switch self {
        case .speaker(let l):     return l.id
        case .systemEvent(let e): return e.id
        }
    }

    // MARK: - Parsing

    /// Parse one JSONL string into a `TranscriptLine`.  Returns nil when the
    /// line is malformed, ensuring callers' `compactMap` behavior.
    public init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["ts"] as? String else {
            return nil
        }

        let typeValue = obj["type"] as? String

        if typeValue == "system_event" {
            // System-event line.
            let event     = obj["event"]     as? String ?? "screen_highlight"
            let image     = obj["image"]     as? String
            let appName   = obj["app"]       as? String
            let bundleId  = obj["bundle_id"] as? String
            let ocrText   = obj["ocr_text"]  as? String
            var cgRect: CGRect?
            if let rDict = obj["rect"] as? [String: Any],
               let rx = rDict["x"] as? Double,
               let ry = rDict["y"] as? Double,
               let rw = rDict["width"]  as? Double,
               let rh = rDict["height"] as? Double {
                cgRect = CGRect(x: rx, y: ry, width: rw, height: rh)
            }
            self = .systemEvent(SystemEventEntry(
                id: UUID(),
                ts: ts,
                event: event,
                imagePath: image,
                appName: appName,
                bundleId: bundleId,
                ocrText: ocrText,
                rect: cgRect
            ))
        } else {
            // Legacy speaker line: missing `type` => speaker line (AC11).
            guard let speakerRaw = obj["speaker"] as? String,
                  let text       = obj["text"]    as? String else {
                return nil
            }
            self = .speaker(SpeakerLine(
                id: UUID(),
                ts: ts,
                speaker: SpeakerLine.Speaker(rawValue: speakerRaw) ?? .unknown,
                text: text,
                audioStartSeconds: obj["audioStartSeconds"] as? Double,
                audioEndSeconds: obj["audioEndSeconds"] as? Double,
                persistentId: obj["lineId"] as? String,
                speakerLabel: obj["speakerLabel"] as? String
            ))
        }
    }
}

// MARK: - ResolvedSpeaker

/// A speaker resolved from `speakers.json` — connects a transcript speaker
/// key to a People entity (`personId`) plus the display name to show.
public struct ResolvedSpeaker: Sendable {
    public let name: String
    /// peers42 person_id (lowercased email or "name:<normalized>"); nil for
    /// the legacy flat speakers.json shape.
    public let personId: String?

    public init(name: String, personId: String?) {
        self.name = name
        self.personId = personId
    }
}

// MARK: - Path helpers

/// Absolute path to the conversation JSONL file inside `sessionDir`.
public func conversationPath(sessionDir: String) -> String {
    (sessionDir as NSString).appendingPathComponent("conversation.jsonl")
}

/// Absolute path to the optional speakers sidecar inside `sessionDir`.
public func speakersPath(sessionDir: String) -> String {
    (sessionDir as NSString).appendingPathComponent("speakers.json")
}

// MARK: - Parsing functions

/// Parse `conversation.jsonl` line by line. Returns an empty array when the
/// file is missing or contains no decodable lines.
public func parseConversation(sessionDir: String) -> [TranscriptLine] {
    let path = conversationPath(sessionDir: sessionDir)
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        return []
    }
    return raw
        .components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .compactMap { TranscriptLine(jsonString: $0) }
}

/// Load the optional `speakers.json` sidecar that connects transcript
/// speakers to People entities. Written best-effort by the end-of-meeting
/// attribution pass (PromptRegistry.meetingEnded). Current shape:
///
///   { "<speakerKey>": { "person_id": "<id>", "name": "<Display Name>" } }
///
/// Back-compat: the legacy flat shape `{ "<speakerKey>": "<Display Name>" }`
/// (no person_id) is still accepted.
///
/// When absent or malformed, returns an empty dictionary.
public func loadSpeakers(sessionDir: String) -> [String: ResolvedSpeaker] {
    let path = speakersPath(sessionDir: sessionDir)
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    var out: [String: ResolvedSpeaker] = [:]
    for (key, value) in obj {
        if let name = value as? String {
            // Legacy flat shape: key → display name.
            out[key] = ResolvedSpeaker(name: name, personId: nil)
        } else if let dict = value as? [String: Any] {
            // Rich shape: key → { person_id, name }.
            let name = (dict["name"] as? String) ?? key
            let personId = dict["person_id"] as? String
            out[key] = ResolvedSpeaker(name: name, personId: personId)
        }
    }
    return out
}

/// Write (or update) one entry in the `speakers.json` sidecar, in the rich
/// `{ "<speakerKey>": { "person_id": "<id>", "name": "<Display Name>" } }`
/// shape `loadSpeakers` prefers. Read-modify-write over the whole file so
/// concurrent entries (e.g. one per diarized voice) accumulate rather than
/// clobber each other; other keys are left untouched.
///
/// Used by the transcript UI's "who is this?" resolver (any speakerKey —
/// today that's a diarized voiceId like "Voice A", or the legacy "Them")
/// and, later, the meeting-end attribution pass. Creates the file (and
/// session directory) if needed.
public func saveSpeaker(sessionDir: String, speakerKey: String, name: String, personId: String?) {
    let path = speakersPath(sessionDir: sessionDir)
    var obj: [String: Any] = [:]
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        obj = existing
    }

    var entry: [String: Any] = ["name": name]
    if let personId { entry["person_id"] = personId }
    obj[speakerKey] = entry

    do {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sessionDir) {
            try fm.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        // Best-effort sidecar, same as the rest of speakers.json — a failed
        // write here degrades to "not yet attributed", never a crash.
    }
}
