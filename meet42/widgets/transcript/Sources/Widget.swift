// Widget.swift — meet42's Transcript widget (meet42-plugin-conversion, s14;
// meet42-detection-rework).
//
// A TILE (conversation.jsonl → chat bubbles) + a stateful PILL (RECORDING /
// ENDED / idle recording accessory). No background agent — the calendar
// widget's detection agent (meet42-detection-rework) now owns the ENTIRE
// recording lifecycle (start on Yes/auto-start, stop on its own 5s
// stop-grace) for calls it detects; this widget only drives the MANUAL
// Record/Stop controls and renders truth.
//
//   • Tile — Work42App/Meetings/TranscriptWidgetView. Reads
//            `<dir>/conversation.jsonl` (+ optional `speakers.json`) and
//            renders each utterance as a Work42UI `ChatBubble` (You =
//            trailing/accent, Them = leading/speaker-hue once matched else
//            neutral, unknown = leading/neutral). The Flow42Core
//            `TranscriptStore` parser + `FileWatcher` are reimplemented
//            locally (no Flow42Core import).
//   • Pill  — Work42App/Dictation/EventSessionAccessory, RECORDING + ENDED
//            states only (+ a plain idle). The DETECTED state is dropped —
//            the calendar widget owns it. Visuals kept: purple #7C3AED, the
//            Stop capsule with a live monospaced `M:SS` timer.
//
// RECORDING TRUTH, per meet42-detection-rework's singleton redesign: `meet42
// record status` is the single source of truth for "is MY session the one
// currently recording" (AC7) — NOT session storage. `SessionServices.storage`
// is FILE-backed for a non-task session (`SessionStorageBackend`), a
// DIFFERENT store than `work42 storage set/get` (always work42.db) — so
// `meeting/started_at`/`ended_at` (written for the workflow gate, AC9) are
// read back via the SHELLED CLI (`work42 storage get --session <id> ...`),
// never via `services.storage`, to distinguish "never recorded" from
// "recorded, then ended" for the pill's transitional ENDED state. Manual
// Record/Stop share the SAME start-sequence tail the detection agent uses:
// `meet42 record start` is a detached, fire-and-forget process (not via
// `WidgetShellService`, which is bounded to 10s and would kill the
// never-exiting daemon), confirmed via a bounded `meet42 record status` poll.

import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42WidgetKit

// MARK: - Palette (app-private constants redefined locally)

/// Meeting-recording accent — the brand violet (#7C3AED). Purple = "recording a
/// meeting". `meetingRecordingPurple` is app-private (`EventSessionAccessory`),
/// so it is redefined here.
private let meetingRecordingPurple = Color(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255)
/// Lighter violet for on-dark countdown copy (#C4B5FD).
private let meetingRecordingPurpleLight = Color(red: 0xC4 / 255, green: 0xB5 / 255, blue: 0xFD / 255)

// MARK: - TranscriptLine (local Flow42Core.TranscriptStore mirror)

/// Local reimplementation of `Flow42Core.TranscriptStore.TranscriptLine`.
/// Parses the exact `conversation.jsonl` shape meet42's engine writes
/// (`Meet42Capture/MeetingTranscriptionEngine.swift` — `ConversationLine` +
/// `SystemEventLine`): a speaker line
///   { "ts", "speaker": "You"|"Them", "text", "lineId", "speakerLabel"?, … }
/// or a system-event line (missing-`type` ⇒ speaker line, for back-compat)
///   { "ts", "type": "system_event", "event", "image"?, "app"?, "bundle_id"?,
///     "ocr_text"?, "rect": {x,y,width,height} }.
enum TranscriptLine: Identifiable {

    struct SpeakerLine {
        let id: UUID
        let ts: String
        let speaker: Speaker
        let text: String
        let persistentId: String?
        let speakerLabel: String?

        enum Speaker: String {
            case you = "You"
            case them = "Them"
            case unknown
        }
    }

    struct SystemEventEntry {
        let id: UUID
        let ts: String
        let event: String
        let imagePath: String?
        let appName: String?
        let bundleId: String?
        let ocrText: String?
        let rect: CGRect?
    }

    case speaker(SpeakerLine)
    case systemEvent(SystemEventEntry)

    var id: UUID {
        switch self {
        case .speaker(let l): return l.id
        case .systemEvent(let e): return e.id
        }
    }

    /// Parse one JSONL string; nil on a malformed line (so callers `compactMap`).
    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["ts"] as? String else {
            return nil
        }

        if (obj["type"] as? String) == "system_event" {
            let event = obj["event"] as? String ?? "screen_highlight"
            var cgRect: CGRect?
            if let rDict = obj["rect"] as? [String: Any],
               let rx = rDict["x"] as? Double,
               let ry = rDict["y"] as? Double,
               let rw = rDict["width"] as? Double,
               let rh = rDict["height"] as? Double {
                cgRect = CGRect(x: rx, y: ry, width: rw, height: rh)
            }
            self = .systemEvent(SystemEventEntry(
                id: UUID(),
                ts: ts,
                event: event,
                imagePath: obj["image"] as? String,
                appName: obj["app"] as? String,
                bundleId: obj["bundle_id"] as? String,
                ocrText: obj["ocr_text"] as? String,
                rect: cgRect
            ))
        } else {
            // Legacy / speaker line: a missing `type` key ⇒ speaker line.
            guard let speakerRaw = obj["speaker"] as? String,
                  let text = obj["text"] as? String else {
                return nil
            }
            self = .speaker(SpeakerLine(
                id: UUID(),
                ts: ts,
                speaker: SpeakerLine.Speaker(rawValue: speakerRaw) ?? .unknown,
                text: text,
                persistentId: obj["lineId"] as? String,
                speakerLabel: obj["speakerLabel"] as? String
            ))
        }
    }
}

/// A speaker resolved from `speakers.json` — the display name + optional
/// peers42 person_id. Local mirror of `Flow42Core.ResolvedSpeaker`.
struct ResolvedSpeaker {
    let name: String
    let personId: String?
}

private func conversationPath(sessionDir: String) -> String {
    (sessionDir as NSString).appendingPathComponent("conversation.jsonl")
}

private func speakersPath(sessionDir: String) -> String {
    (sessionDir as NSString).appendingPathComponent("speakers.json")
}

/// Parse `conversation.jsonl` line by line; empty when missing/undecodable.
private func parseConversation(sessionDir: String) -> [TranscriptLine] {
    guard let raw = try? String(contentsOfFile: conversationPath(sessionDir: sessionDir), encoding: .utf8) else {
        return []
    }
    return raw
        .components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .compactMap { TranscriptLine(jsonString: $0) }
}

/// Load the optional `speakers.json` sidecar. Accepts both the flat
/// `{ "<key>": "<Name>" }` and the rich
/// `{ "<key>": { "person_id": "<id>", "name": "<Name>" } }` shapes.
private func loadSpeakers(sessionDir: String) -> [String: ResolvedSpeaker] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: speakersPath(sessionDir: sessionDir))),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    var out: [String: ResolvedSpeaker] = [:]
    for (key, value) in obj {
        if let name = value as? String {
            out[key] = ResolvedSpeaker(name: name, personId: nil)
        } else if let dict = value as? [String: Any], let name = dict["name"] as? String {
            out[key] = ResolvedSpeaker(name: name, personId: dict["person_id"] as? String)
        }
    }
    return out
}

// MARK: - WidgetFileWatcher (local FileWatcher reimplementation)

/// Minimal self-contained replacement for `Work42App.FileWatcher` — polls the
/// file's (mtime, size) signature every ~0.5s and bumps `version` on change,
/// so a view that reads `version` re-renders as `conversation.jsonl` /
/// `speakers.json` are appended/rewritten out-of-band by the capture daemon.
@Observable
@MainActor
private final class WidgetFileWatcher {

    private(set) var version = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var path: String?
    @ObservationIgnored private var lastSignature = ""

    func watch(_ path: String) {
        guard self.path != path else { return }
        self.path = path
        lastSignature = Self.signature(of: path)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let path else { return }
        let sig = Self.signature(of: path)
        guard sig != lastSignature else { return }
        lastSignature = sig
        version &+= 1
    }

    private static func signature(of path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        return "\(mtime)-\(size)"
    }
}

// MARK: - Shared helpers

/// ISO 8601 (with fractional seconds) of now — matches the format the capture
/// engine writes for `ts`, and what the gates expect for started_at/ended_at.
private func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

/// POSIX single-quote shell escaping — mirrors the calendar widget's
/// `calShellQuote` (duplicated per widget — no shared target).
private func transcriptShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Meet42Trace (duplicated per widget — no shared target; same convention as shell-quote helpers)

/// Append one JSON-line trace event to ~/.work42/meet42/trace.jsonl.
/// Best-effort (never throws, never blocks). Disabled when MEET42_TRACE=0.
private enum Meet42Trace {
    static func log(_ src: String, _ evt: String, _ fields: [String: Any] = [:]) {
        guard ProcessInfo.processInfo.environment["MEET42_TRACE"] != "0" else { return }
        var row = fields
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        row["ts"]  = f.string(from: Date())
        row["pid"] = Int(getpid())
        row["src"] = src
        row["evt"] = evt
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".work42/meet42")
        let path = (root as NSString).appendingPathComponent("trace.jsonl")
        // Rotate past 5 MB.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 {
            rename(path, path + ".1")
        }
        // Ensure the directory exists before opening.
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: nil)
        // O_APPEND|O_CREAT|O_WRONLY: atomic across processes for small writes.
        let fd = open(path, O_APPEND | O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { return }
        line.withCString { _ = write(fd, $0, strlen($0)) }
        close(fd)
    }
}

/// Parse an ISO 8601 timestamp, tolerating presence/absence of fractional secs.
private func parseISO8601(_ ts: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: ts) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: ts)
}

// MARK: - Recording truth (meet42 record status + the workflow-gate storage)

/// Decode target for `meet42 record status --json`. `meet42 record` is now
/// session-agnostic (meet42-recording-lifecycle-rework s1) — its status is
/// keyed by `dir` (the recording's own directory), not a session id. `
/// sessionId` is kept decodable (always nil against the real CLI now) ONLY
/// because the manual Record/Stop intents below still reference it pending
/// their own rewrite (s5) — remove once that lands.
private struct TranscriptRecordStatusPayload: Decodable {
    let recording: Bool
    let dir: String?
    let sessionId: String?
}

/// Unwrap a canonical-JSON-quoted string from `work42 storage get`'s raw
/// (non-`--json`) stdout, e.g. `"2026-10-02T00:14:16.123Z"` -> the inner
/// string. nil when unset (the CLI exits non-zero) or the output isn't a
/// quoted JSON string.
/// Read `meeting/recording_dir` from THIS session's own storage via the
/// SDK's native `services.storage` — NOT the shelled `work42 storage get`
/// CLI. For a non-task session (exactly what an "event" meeting session is),
/// `WidgetCommandRunner` injects `WORK42_SESSION_DIR` as the session's
/// WORKTREE path, but `storage.json` actually lives in the chat-session
/// metadata directory — a real work42-core bug (`SessionDiscovery`/
/// `StorageCommand` resolve the wrong directory for a non-task session's
/// env-matched/registry-matched storage lookup) that silently breaks the
/// shelled CLI path. `services.storage` sidesteps it entirely: it's backed
/// directly by `SessionStorageBackend(sessionDirectory: resolved.
/// sessionDirectory)` — the CORRECT directory, no shell/CLI indirection at
/// all. nil for a session with no recording attached yet (a plain event
/// session, or one where Record hasn't been clicked).
private func fetchRecordingDir(services: SessionServices) async -> String? {
    guard let value = try? await services.storage.get(namespace: "meeting", key: "recording_dir"),
          case .string(let dir) = value
    else { return nil }
    return dir
}

/// Recording truth for one session: `meet42 record status` is the single
/// source of truth for "is MY session's recording the one currently active"
/// (AC7) — compared by DIRECTORY, since `meet42 record` is session-agnostic
/// (meet42-recording-lifecycle-rework s1) and no longer knows about session
/// ids or worktree slugs at all. `recordingDir`/`startedAt`/`hasEnded` are
/// read via `services.storage` (see `fetchRecordingDir`'s doc for why that's
/// the correct API, not the shelled CLI, for a non-task session).
private struct RecordingSnapshot {
    /// This session's `meeting/recording_dir` pointer, or nil if no
    /// recording has ever been attached to it.
    let recordingDir: String?
    let isRecordingThisSession: Bool
    let startedAt: Date?
    let hasEnded: Bool
}

private func fetchRecordingSnapshot(services: SessionServices) async -> RecordingSnapshot {
    guard services.sessionId != nil else {
        return RecordingSnapshot(recordingDir: nil, isRecordingThisSession: false, startedAt: nil, hasEnded: false)
    }
    let recordingDir = await fetchRecordingDir(services: services)
    var isRecording = false
    if let recordingDir,
       let r = try? await services.shell.run(command: "meet42 record status --json"),
       r.exitCode == 0, let data = r.stdout.data(using: .utf8),
       let status = try? JSONDecoder().decode(TranscriptRecordStatusPayload.self, from: data),
       status.recording, status.dir == recordingDir {
        isRecording = true
    }
    var startedAt: Date?
    if let value = try? await services.storage.get(namespace: "meeting", key: "started_at"),
       case .string(let iso) = value {
        startedAt = parseISO8601(iso)
    }
    var hasEnded = false
    if let value = try? await services.storage.get(namespace: "meeting", key: "ended_at"),
       case .string(let iso) = value, parseISO8601(iso) != nil {
        hasEnded = true
    }
    return RecordingSnapshot(
        recordingDir: recordingDir, isRecordingThisSession: isRecording, startedAt: startedAt, hasEnded: hasEnded
    )
}

/// Resolve a meet42 subcommand invocation: the app's own bundled binary first
/// (`Contents/MacOS/meet42`), falling back to a PATH lookup via `/usr/bin/env`
/// for non-bundle dev contexts. Duplicated from the calendar widget — no
/// shared target between plugin widgets.
private func transcriptMeet42Invocation(
    verb: String, extraArgs: [String] = []
) -> (executable: URL, arguments: [String]) {
    let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/meet42")
    if FileManager.default.fileExists(atPath: bundled.path) {
        return (bundled, [verb] + extraArgs)
    }
    return (URL(fileURLWithPath: "/usr/bin/env"), ["meet42", verb] + extraArgs)
}

/// Launch `meet42 record start` as a detached, fire-and-forget process — NOT
/// via `WidgetShellService` (bounded to 10s; `record start` daemonizes via
/// setsid+execve with no fork, so it never exits on its own while recording,
/// and the bounded shell service would kill it).
private func fireTranscriptRecordStart(sessionDir: String) {
    let (exe, args) = transcriptMeet42Invocation(
        verb: "record", extraArgs: ["start", "--session-dir", sessionDir]
    )
    let process = Process()
    process.executableURL = exe
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// Load just the meeting title from `<dir>/meeting.json` (best-effort) so the
/// pill can name the call. Falls back to "Meeting".
private func meetingTitle(dir: String?) -> String {
    guard let dir else { return "Meeting" }
    let path = (dir as NSString).appendingPathComponent("meeting.json")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let event = obj["event"] as? [String: Any],
          let title = event["title"] as? String,
          !title.isEmpty else {
        return "Meeting"
    }
    return title
}

// MARK: - TranscriptWidget

@Observable
@MainActor
final class TranscriptWidget: Work42Widget, Work42WidgetPill {

    let id = "transcript"
    let title = "Transcript"
    let icon = "waveform"

    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 280, height: 220) }

    // MARK: - Recording state (drives action-area intent isEnabled / labels)

    /// True when `meet42 record status` reports THIS session as the active
    /// recording (AC7 — the single source of truth, not session storage).
    /// Drives the `record` intent (hidden while true) and the `stop` intent
    /// (visible/enabled while true). Observed by the host at render time.
    private(set) var isRecordingThisSession: Bool = false

    /// `meeting/started_at`, read via the shelled CLI; drives the stop
    /// intent's live mm:ss timer.
    private(set) var recordingStartedAt: Date? = nil

    /// `meeting/ended_at` is set but this session isn't the active recording
    /// — drives the reconcile-on-activate re-present (AC8).
    private(set) var hasEndedThisSession: Bool = false

    /// Pre-fetched microphone list for the selectMic menu `options` closure,
    /// which is synchronous and reads this cached value.
    private(set) var micOptions: [WidgetIntentMenuOption] = []

    /// Active session services — set in `activate`, cleared in `deactivate`.
    @ObservationIgnored private var services: SessionServices? = nil

    /// Background state-poll task (recording state + mic options).
    @ObservationIgnored private var statePollTask: Task<Void, Never>? = nil

    // MARK: - Work42Widget.intents

    /// Three pre-conversion action-area intents restored from
    /// `SessionDetailPanel.transcriptIntentSpecs`:
    ///   1. selectMic  — mic-picker menu
    ///   2. record     — purple record.circle icon (hidden while recording)
    ///   3. stop       — purple stop.fill labeled with a live mm:ss timer
    ///                   (visible only while recording)
    var intents: [WidgetIntentSpec] {
        [
            // ── 1. selectMic ─────────────────────────────────────────────────
            WidgetIntentSpec(
                name: "selectMic",
                title: "Choose Microphone",
                icon: "mic",
                placement: [.actionArea],
                actionAreaStyle: .menu(
                    options: { [weak self] in self?.micOptions ?? [] },
                    onSelect: { [weak self] uid in
                        guard let self, let svc = self.services else { return }
                        _ = try? await svc.shell.run(
                            command: "meet42 mics select \"\(uid)\""
                        )
                        // Refresh so the checkmark moves to the new selection.
                        await self.refreshMicOptions()
                    }
                ),
                perform: {}      // never called — action-area-only intent
            ),

            // ── 2. record ────────────────────────────────────────────────────
            // Shares the detection agent's start-sequence tail: fire the
            // singleton daemon detached, confirm via `record status`, then
            // write `meeting/started_at` for the workflow gate (via the CLI —
            // `services.storage` is file-backed for a non-task session and
            // never reaches work42.db).
            WidgetIntentSpec(
                name: "record",
                title: "Record",
                icon: "record.circle",
                brandColorHex: "#7C3AED",
                placement: [.actionArea],
                actionAreaStyle: .icon,
                isEnabled: { [weak self] in !(self?.isRecordingThisSession ?? false) },
                perform: { [weak self] in
                    guard let self, let svc = self.services,
                          let dir = svc.worktreePath, let sessionId = svc.sessionId else { return }
                    // Belt-and-suspenders registration — see
                    // fetchRecordingSnapshot's comment: `work42 storage set
                    // --session <id>` only resolves without this when the
                    // override happens to match the CALLING process's own
                    // WORK42_SESSION_ID, which is usually true here (clicking
                    // Record on the session you're viewing) but not
                    // guaranteed.
                    try? ArtifactRuntime.register(sessionId: sessionId, directory: dir)
                    fireTranscriptRecordStart(sessionDir: dir)

                    // Compare against the dir's basename, not sessionId — see
                    // fetchRecordingSnapshot's comment: `meet42 record start`
                    // derives its own sessionId from the session DIRECTORY's
                    // last path component, not the semantic session UUID.
                    let recordSlug = (dir as NSString).lastPathComponent
                    var confirmed = false
                    for _ in 0..<4 {
                        try? await Task.sleep(nanoseconds: 750_000_000)
                        if let r = try? await svc.shell.run(command: "meet42 record status --json"),
                           r.exitCode == 0, let data = r.stdout.data(using: .utf8),
                           let status = try? JSONDecoder().decode(TranscriptRecordStatusPayload.self, from: data),
                           status.recording, status.sessionId == recordSlug {
                            confirmed = true
                            break
                        }
                    }
                    guard confirmed else { return }

                    let startedAtJSON = transcriptShellQuote("\"\(isoNow())\"")
                    _ = try? await svc.shell.run(
                        command: "work42 storage set --session \(transcriptShellQuote(sessionId)) meeting/started_at \(startedAtJSON)"
                    )
                    await self.refreshRecordingState()
                }
            ),

            // ── 3. stop ──────────────────────────────────────────────────────
            WidgetIntentSpec(
                name: "stop",
                title: "Stop",
                icon: "stop.fill",
                brandColorHex: "#7C3AED",
                placement: [.actionArea],
                actionAreaStyle: .labeled,
                isEnabled: { [weak self] in self?.isRecordingThisSession ?? false },
                actionAreaTitle: { [weak self] in
                    guard let self, let started = self.recordingStartedAt else {
                        return "Stop"
                    }
                    let elapsed = max(0, Int(Date().timeIntervalSince(started)))
                    return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
                },
                livePeriodicTick: 1,
                perform: { [weak self] in
                    guard let self, let svc = self.services,
                          let dir = svc.worktreePath, let sessionId = svc.sessionId else { return }
                    // meet42 record stop just touches a marker file and
                    // returns immediately — safe via the bounded shell service.
                    _ = try? await svc.shell.run(
                        command: "meet42 record stop --session-dir \"\(dir)\""
                    )
                    let endedAtJSON = transcriptShellQuote("\"\(isoNow())\"")
                    _ = try? await svc.shell.run(
                        command: "work42 storage set --session \(transcriptShellQuote(sessionId)) meeting/ended_at \(endedAtJSON)"
                    )
                    await self.refreshRecordingState()
                }
            ),
        ]
    }

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        statePollTask?.cancel()
        statePollTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshRecordingState()
            await self.refreshMicOptions()
            // Reconcile on activate (AC8): a recording's lifetime is no
            // longer tied to this widget (or the app) being alive — the
            // record daemon self-watches its own trigger call and self-stops
            // independent of everything else (meet42-recording-lifecycle-
            // rework s2) — so if THIS session's recording survived an app
            // relaunch/crash, or ended while nothing was watching, re-float
            // its pill rather than leaving the user with no visible state.
            if self.isRecordingThisSession || self.hasEndedThisSession,
               let sessionId = services.sessionId {
                try? await services.pill.present(widgetId: "transcript", sessionId: sessionId)
            }
            while !Task.isCancelled {
                await self.refreshRecordingState()
                await self.refreshMicOptions()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func deactivate() {
        statePollTask?.cancel()
        statePollTask = nil
        services = nil
        isRecordingThisSession = false
        recordingStartedAt = nil
        hasEndedThisSession = false
        micOptions = []
    }

    // MARK: - State refresh helpers

    /// Refresh `isRecordingThisSession`/`recordingStartedAt`/
    /// `hasEndedThisSession` from the single source of truth (`meet42 record
    /// status` + the workflow-gate storage).
    private func refreshRecordingState() async {
        guard let svc = services else { return }
        let snapshot = await fetchRecordingSnapshot(services: svc)
        isRecordingThisSession = snapshot.isRecordingThisSession
        recordingStartedAt = snapshot.startedAt
        hasEndedThisSession = snapshot.hasEnded
    }

    /// Shell `meet42 mics --json` and refresh the cached `micOptions` list.
    private func refreshMicOptions() async {
        guard let svc = services else { return }
        guard let result = try? await svc.shell.run(command: "meet42 mics --json"),
              result.exitCode == 0 else { return }
        guard let data = result.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data)
                  as? [[String: Any]] else { return }
        micOptions = rows.compactMap { row -> WidgetIntentMenuOption? in
            guard let uid  = row["uid"]  as? String,
                  let name = row["name"] as? String else { return nil }
            let isSelected = row["selected"] as? Bool ?? false
            return WidgetIntentMenuOption(
                id: uid, title: name, icon: "mic", isSelected: isSelected
            )
        }
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(TranscriptTileView(services: services))
    }

    // MARK: Work42WidgetPill

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(RecordingAccessory(services: services))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            // The Event accessory's size (EventSessionAccessory.initialSize).
            preferredSize: WidgetMinSize(width: 412, height: 108),
            title: title,
            icon: icon
        )
    }
}

// MARK: - TranscriptTileView (the tile — conversation.jsonl → ChatBubbles)

/// Faithful port of the app's `TranscriptWidgetView`: renders
/// `conversation.jsonl` live as chat bubbles. The app's "who is this?" speaker
/// resolver popover is DROPPED (it required Flow42Core's `PeopleStore`); the
/// avatar is inert here. System-event cards render without the image thumbnail
/// (loading a file image needs AppKit/ImageIO, outside the allowed imports).
private struct TranscriptTileView: View {
    let services: SessionServices

    @State private var conversationWatcher = WidgetFileWatcher()
    @State private var speakersWatcher = WidgetFileWatcher()
    /// This session's `meeting/recording_dir` pointer — the transcript now
    /// lives there, not in the session's own worktree (meet42-recording-
    /// lifecycle-rework s1: `meet42 record` owns its own store). nil until
    /// resolved (a quick shell call, so this is near-instant in the common
    /// case where the pointer was already seeded before this pill/tile ever
    /// mounted — see the `.task` below for the "Record clicked after the
    /// tile was already open" case, where it resolves once the pointer
    /// appears).
    @State private var recordingDir: String?

    var body: some View {
        // Register both watchers as dependencies so the body re-runs on change.
        let _ = conversationWatcher.version
        let _ = speakersWatcher.version
        let lines = recordingDir.map { parseConversation(sessionDir: $0) } ?? []
        let speakers = recordingDir.map { loadSpeakers(sessionDir: $0) } ?? [:]

        return Group {
            if lines.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(lines) { line in
                                transcriptBubble(for: line, speakers: speakers)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, DT.s12)
                        .padding(.vertical, DT.s8)
                    }
                    .onChange(of: lines.count) { _, _ in
                        if let last = lines.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .task {
            // Poll until the pointer resolves, then stop — it's set once
            // and never changes for a session's lifetime, but it may not
            // exist YET if this tile is opened before Record is ever
            // clicked (a plain session with no recording attached).
            while recordingDir == nil, !Task.isCancelled {
                recordingDir = await fetchRecordingDir(services: services)
                if recordingDir == nil {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        .onChange(of: recordingDir) { _, newDir in
            guard let newDir else { return }
            conversationWatcher.watch(conversationPath(sessionDir: newDir))
            speakersWatcher.watch(speakersPath(sessionDir: newDir))
        }
        .onAppear {
            if let recordingDir {
                conversationWatcher.watch(conversationPath(sessionDir: recordingDir))
                speakersWatcher.watch(speakersPath(sessionDir: recordingDir))
            }
        }
        .onDisappear {
            conversationWatcher.stop()
            speakersWatcher.stop()
        }
    }

    @ViewBuilder
    private func transcriptBubble(
        for line: TranscriptLine,
        speakers: [String: ResolvedSpeaker]
    ) -> some View {
        switch line {
        case .speaker(let s): speakerBubble(for: s, speakers: speakers)
        case .systemEvent(let e): systemEventCard(for: e)
        }
    }

    @ViewBuilder
    private func speakerBubble(
        for line: TranscriptLine.SpeakerLine,
        speakers: [String: ResolvedSpeaker]
    ) -> some View {
        switch line.speaker {
        case .you:
            ChatBubble(
                side: .trailing,
                style: .accent,
                header: ChatBubbleHeader(timestamp: parseISO8601(line.ts))
            ) {
                Text(line.text)
                    .font(.system(size: DT.f12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .environment(\.chatBubbleForegroundColor, DT.accentForeground)
            }

        case .them:
            // Speaker key precedence: this line's own diarized label first (so
            // distinct remote voices get distinct identities), then the legacy
            // "Them"/"them" keys. A speaker stays fully NEUTRAL (grey) until
            // MATCHED to a person in speakers.json; once matched the person's
            // stable palette color paints avatar + name + bubble tint.
            let speakerKey = line.speakerLabel ?? "Them"
            let resolved = speakers[speakerKey] ?? speakers["Them"] ?? speakers["them"]
            let displayName = resolved?.name ?? speakerKey
            let matchedColor = resolved.map { personColor(for: $0.personId ?? $0.name) }
            let style: ChatBubbleStyle = matchedColor.map { .speaker($0) } ?? .neutral
            let avatarColor: Color = matchedColor ?? Color.gray
            ChatBubble(
                side: .leading,
                style: style,
                header: ChatBubbleHeader(
                    name: displayName,
                    avatar: .initials(initialsString(for: displayName), color: avatarColor),
                    timestamp: parseISO8601(line.ts)
                )
            ) {
                Text(line.text)
                    .font(.system(size: DT.f12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

        case .unknown:
            ChatBubble(
                side: .leading,
                style: .neutral,
                header: ChatBubbleHeader(timestamp: parseISO8601(line.ts))
            ) {
                Text(line.text)
                    .font(.system(size: DT.f12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    /// A system-event entry as a CENTERED, visually distinct card. The image
    /// thumbnail the app showed is omitted (no AppKit/ImageIO in a plugin
    /// widget); app name + OCR text + timestamp are preserved.
    @ViewBuilder
    private func systemEventCard(for entry: TranscriptLine.SystemEventEntry) -> some View {
        VStack(alignment: .center, spacing: DT.s8) {
            if let app = entry.appName, !app.isEmpty {
                HStack(spacing: DT.s4) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: DT.f10))
                        .foregroundStyle(DT.textTertiary)
                    Text(app)
                        .font(.system(size: DT.f11, weight: .medium))
                        .foregroundStyle(DT.textSecondary)
                }
            }
            if let ocr = entry.ocrText, !ocr.isEmpty {
                Text(ocr)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(DT.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
            }
            if let parsedDate = parseISO8601(entry.ts) {
                Text(parsedDate, style: .time)
                    .font(.system(size: DT.f10))
                    .foregroundStyle(DT.textTertiary)
            }
        }
        .padding(.horizontal, DT.s16)
        .padding(.vertical, DT.s12)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s4)
    }

    private var emptyState: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "ear.and.waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.textTertiary)
            Text("Waiting to listen\u{2026}")
                .font(.system(size: DT.f13, weight: .medium))
                .foregroundStyle(DT.textTertiary)
            Text("Transcript lines appear here as the meeting progresses.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - RecModel (pill state — the single source of truth)

/// Drives the recording accessory. `state` + `startedAt`/`endedAt` are derived
/// by polling `meeting/started_at` + `meeting/ended_at` storage: `ended` when
/// ended_at is set, `recording` when started_at is set and not ended, else
/// `idle`. The pill's Stop button writes through the same storage.
@Observable
@MainActor
private final class RecModel {

    enum State { case idle, recording, ended }

    var state: State = .idle
    var startedAt: Date?
    var endedAt: Date?
    var title: String = "Meeting"

    @ObservationIgnored private let services: SessionServices
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(services: SessionServices) {
        self.services = services
        self.title = meetingTitle(dir: services.worktreePath)
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// `meet42 record status` is the single source of truth for `.recording`
    /// (AC7); `meeting/ended_at` (read via the shelled CLI — `services.storage`
    /// is file-backed for a non-task session and never reaches the
    /// work42.db write the workflow gate / this check both need) distinguishes
    /// `.ended` from `.idle` once it's no longer the active recording.
    private func refresh() async {
        let snapshot = await fetchRecordingSnapshot(services: services)
        startedAt = snapshot.startedAt
        if snapshot.isRecordingThisSession {
            state = .recording
            endedAt = nil
        } else if snapshot.hasEnded {
            state = .ended
        } else {
            state = .idle
        }
    }

    /// Stop capture now: `meet42 record stop` + write ended_at + dismiss the
    /// pill. Reused by both the RECORDING Stop and the ENDED Stop controls.
    func stopRecording() {
        Task { @MainActor [weak self] in
            guard let self, let sessionId = self.services.sessionId else { return }
            _ = try? await self.services.shell.run(command: "meet42 record stop --session-dir \"$(pwd)\"")
            let endedAtJSON = transcriptShellQuote("\"\(isoNow())\"")
            _ = try? await self.services.shell.run(
                command: "work42 storage set --session \(transcriptShellQuote(sessionId)) meeting/ended_at \(endedAtJSON)"
            )
            try? await self.services.pill.dismiss(widgetId: "transcript")
            await self.refresh()
        }
    }
}

// MARK: - RecordingAccessory (the pill — RECORDING / ENDED / idle)

/// The recording accessory pill. Ports `EventSessionAccessory`'s recording +
/// endedPrompt visuals (the DETECTED state belongs to the calendar widget) plus
/// a plain idle state, rendered on a self-contained dark card so the white-on-
/// dark visuals stay legible regardless of the host panel's surface.
///
/// Dropped vs the app accessory (need app-internal plumbing a plugin pill lacks,
/// documented): the secondary buttons — "Open Session" (recording), the ＋ float
/// menu, and "Stay" (ended). The medallion resolves no source-app icon (that
/// bundle id came from the app-side detection coordinator); it shows the purple
/// video fallback.
private struct RecordingAccessory: View {
    let services: SessionServices

    @State private var model: RecModel

    init(services: SessionServices) {
        self.services = services
        _model = State(wrappedValue: RecModel(services: services))
    }

    private let cardWidth: CGFloat = 412

    private var isEnded: Bool { model.state == .ended }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if isEnded { endedRow }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if isEnded { countdownBar }
        }
        .frame(width: cardWidth, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.state)
        .environment(\.controlActiveState, .active)
        .task { model.start() }
        .onDisappear { model.stopPolling() }
    }

    // MARK: Header (medallion + name/subtitle, + inline Stop while recording)

    private var header: some View {
        HStack(spacing: 11) {
            medallion
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if model.state == .recording { stopControl }
        }
        .frame(height: 36)
    }

    private var subtitle: String {
        switch model.state {
        case .idle: return "Not recording"
        case .recording: return "Recording"
        case .ended: return "Recording ended"
        }
    }

    // MARK: Ended row ("Auto-stopping in Ns" + Stop) + countdown bar

    private var endedRow: some View {
        HStack(spacing: 10) {
            TimelineView(.animation) { ctx in
                Text("Auto-stopping in \(countdownSeconds(at: ctx.date))s")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(meetingRecordingPurpleLight)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            stopControl
        }
        .frame(height: 32)
    }

    /// Fixed-size purple grace bar flush along the bottom (no GeometryReader).
    private var countdownBar: some View {
        TimelineView(.animation) { ctx in
            let frac = countdownFraction(at: ctx.date)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08))
                Rectangle()
                    .fill(meetingRecordingPurple)
                    .frame(width: max(0, cardWidth * frac))
                    .shadow(color: meetingRecordingPurple.opacity(0.7), radius: 4)
            }
            .frame(width: cardWidth, height: 3)
        }
    }

    // MARK: Medallion (purple video fallback — no source-app icon in a plugin)

    private var medallion: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(meetingRecordingPurple.opacity(0.9))
            .overlay(
                Image(systemName: "video.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }

    // MARK: Stop control (white stop.fill + live monospaced M:SS, purple capsule)

    @ViewBuilder
    private var stopControl: some View {
        Group {
            if let started = model.startedAt {
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    stopButton(elapsed: max(0, Int(ctx.date.timeIntervalSince(started))))
                }
            } else {
                stopButton(elapsed: 0)
            }
        }
        .padding(.horizontal, 8)
        .meetingPurpleCapsule()
    }

    private func stopButton(elapsed: Int) -> some View {
        Button(action: { model.stopRecording() }) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .frame(width: 20, height: 32)
                Text(Self.timeString(elapsed))
                    .font(.system(size: DT.f11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.trailing, DT.s4)
            }
            .frame(minHeight: 32)
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .help("Stop recording")
    }

    private static func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Countdown math (10s grace, anchored at ended_at)

    private func countdownFraction(at date: Date) -> CGFloat {
        guard let start = model.endedAt else { return 0 }
        let remaining = max(0, 10 - date.timeIntervalSince(start))
        return CGFloat(remaining / 10)
    }

    private func countdownSeconds(at date: Date) -> Int {
        guard let start = model.endedAt else { return 0 }
        let remaining = max(0, 10 - date.timeIntervalSince(start))
        return max(1, Int(ceil(remaining)))
    }
}

// MARK: - meetingPurpleCapsule (local port of the app-private modifier)

private extension View {
    /// The meeting-recording purple capsule surface — a REAL fill (not system
    /// `.glassEffect`, which desaturates to grey in the non-activating pill
    /// panel), with a top sheen + soft glow. Local port of
    /// `EventSessionAccessory`'s app-private `meetingPurpleCapsule`.
    func meetingPurpleCapsule() -> some View {
        background(
            Capsule(style: .continuous)
                .fill(meetingRecordingPurple)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(.linearGradient(
                            colors: [.white.opacity(0.18), .white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        ))
                )
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                .shadow(color: meetingRecordingPurple.opacity(0.45), radius: 5, y: 1)
        )
    }
}

// MARK: - Widget entry-point ABI
//
// No background agent: the calendar widget's detection agent
// (meet42-detection-rework) owns the whole recording lifecycle for calls it
// detects (start via meet42 record start, stop via its own 5s stop-grace on
// the event-driven meet42 watch stream). This widget only drives the MANUAL
// Record/Stop controls (above) and renders recording truth — no polling, no
// bounded single-shot `meet42 watch` probe hack.

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(TranscriptWidget())
    }
    return result
}
