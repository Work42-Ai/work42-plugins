// Widget.swift — meet42's Transcript widget (meet42-plugin-conversion, s14;
// meet42-detection-rework).
//
// A TILE (conversation.jsonl → chat bubbles), a stateful active-meeting PILL,
// and a session-scoped background agent. Calendar detects and starts meetings;
// Transcript owns the active recording UI and mic-close decision after handoff.
//
//   • Tile — Work42App/Meetings/TranscriptWidgetView. Reads
//            `<dir>/conversation.jsonl` (+ optional `speakers.json`) and
//            renders each utterance as a Work42UI `ChatBubble` (You =
//            trailing/accent, Them = leading/speaker-hue once matched else
//            neutral, unknown = leading/neutral). The Flow42Core
//            `TranscriptStore` parser + `FileWatcher` are reimplemented
//            locally (no Flow42Core import).
//   • Pill  — two-row active state with source-app identity, Open Session,
//            scheduled-time rail, Stop timer, and 10-second Stay/Stop prompt.
//
// RECORDING TRUTH, per meet42-detection-rework's singleton redesign: `meet42
// record status` is the single source of truth for "is MY session the one
// currently recording" (AC7) — NOT session storage. `SessionServices.storage`
// is FILE-backed for a non-task session (`SessionStorageBackend`), a
// DIFFERENT store than `work42 storage set/get` (always work42.db) — so
// Stable `meeting/*` metadata is read through `services.storage`; writes to
// that cross-widget namespace use the shelled `work42 storage` command.
// Manual Record/Stop share the same capture primitive as Calendar:
// `meet42 record start` is a detached, fire-and-forget process (not via
// `WidgetShellService`, which is bounded to 10s and would kill the
// never-exiting daemon), confirmed via a bounded `meet42 record status` poll.

import AppKit
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

/// Line-buffered stdout reader driven by `FileHandle.readabilityHandler`
/// (callback on read-readiness) rather than `FileHandle.bytes.lines`, whose
/// `for await` performs a synchronous blocking `read()` on whichever thread
/// picks up the continuation — pinning one of Swift Concurrency's limited,
/// process-wide cooperative threads for as long as the pipe stays open
/// (here, the lifetime of a `meet42 watch` process, which by design never
/// exits on its own). Mirrors the calendar widget's `calAsyncLines`.
private func transcriptAsyncLines(from fileHandle: FileHandle) -> AsyncStream<String> {
    // GCD serializes a single FileHandle's readabilityHandler invocations
    // (one event-source callback at a time), so this buffer is never
    // touched concurrently despite the compiler being unable to prove it.
    nonisolated final class LineBuffer: @unchecked Sendable {
        private var data = Data()
        nonisolated func extractLines(appending chunk: Data) -> [String] {
            data.append(chunk)
            var lines: [String] = []
            while let newline = data.firstIndex(of: 0x0A) {
                if let line = String(data: data[..<newline], encoding: .utf8) {
                    lines.append(line)
                }
                data.removeSubrange(...newline)
            }
            return lines
        }
        nonisolated func drainRemainder() -> String? {
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return nil }
            return line
        }
    }

    return AsyncStream { continuation in
        let buffer = LineBuffer()
        fileHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                if let line = buffer.drainRemainder() { continuation.yield(line) }
                continuation.finish()
                return
            }
            for line in buffer.extractLines(appending: chunk) {
                continuation.yield(line)
            }
        }
        continuation.onTermination = { _ in
            fileHandle.readabilityHandler = nil
        }
    }
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
/// keyed by `dir` (the recording's own directory), not a session id.
private struct TranscriptRecordStatusPayload: Decodable {
    let recording: Bool
    let dir: String?
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
/// ids or worktree slugs at all. `recordingDir` and `startedAt` are
/// read via `services.storage` (see `fetchRecordingDir`'s doc for why that's
/// the correct API, not the shelled CLI, for a non-task session).
private struct RecordingSnapshot {
    /// This session's `meeting/recording_dir` pointer, or nil if no
    /// recording has ever been attached to it.
    let recordingDir: String?
    let isRecordingThisSession: Bool
    let startedAt: Date?
}

private func fetchRecordingSnapshot(services: SessionServices) async -> RecordingSnapshot {
    guard services.sessionId != nil else {
        return RecordingSnapshot(recordingDir: nil, isRecordingThisSession: false, startedAt: nil)
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
    return RecordingSnapshot(
        recordingDir: recordingDir, isRecordingThisSession: isRecording, startedAt: startedAt
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

/// `meet42 record start --manual --json`'s pre-daemonize stdout line.
private struct TranscriptRecordStartResult: Decodable {
    let recordingId: String
    let dir: String
}

/// Launch `meet42 record start --manual` as a DETACHED process — NOT via
/// `WidgetShellService` (bounded to 10s; `record start` daemonizes via
/// setsid+execve with no fork, so it never exits on its own while recording,
/// and the bounded shell service would kill it). `--manual` leaves stop policy
/// with the explicit Transcript controls. Unlike the old fire-and-forget
/// version, this DOES need the daemon's stdout (the `{recordingId,dir}` line
/// it prints before daemonizing, per s1) so the caller can seed this
/// session's storage pointer — mirrors the calendar widget's
/// `fireRecordStart`: redirect to a temp file and poll for the line to
/// appear (NOT for the process to exit, since it deliberately never does).
private func fireTranscriptRecordStart() async -> TranscriptRecordStartResult? {
    let (exe, args) = transcriptMeet42Invocation(
        verb: "record", extraArgs: ["start", "--manual", "--json"]
    )
    let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("meet42-record-\(UUID().uuidString).json")
    guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
          let outHandle = try? FileHandle(forWritingTo: outURL)
    else { return nil }
    defer {
        try? outHandle.close()
        try? FileManager.default.removeItem(at: outURL)
    }

    let process = Process()
    process.executableURL = exe
    process.arguments = args
    process.standardOutput = outHandle
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }

    // Poll for the stdout line to appear — it prints well under 1s after
    // launch (before the slow capture init); 5s total budget leaves
    // generous headroom. If the singleton is already held elsewhere, the
    // daemon prints a refusal payload instead, which fails to decode as
    // TranscriptRecordStartResult — correctly surfacing as "didn't start."
    for _ in 0..<50 {
        if let data = try? Data(contentsOf: outURL), !data.isEmpty,
           let result = try? JSONDecoder().decode(TranscriptRecordStartResult.self, from: data) {
            return result
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
}

// MARK: - Active meeting ownership

@Observable
@MainActor
private final class TranscriptMeetingModel {
    enum Phase { case inactive, active, endPrompt, stopped }

    let sessionId: String
    var phase: Phase = .inactive
    var title = "Meeting"
    var sourceApp = "Meeting"
    var sourceBundleId: String?
    var sourceIcon: NSImage?
    var recordingDir: String?
    var startedAt: Date?
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var promptStartedAt: Date?

    @ObservationIgnored private var services: WidgetBackgroundServices?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var watchProcess: Process?
    @ObservationIgnored private var watchedBundleId: String?
    @ObservationIgnored private var suppressCloseUntilOpen = false
    @ObservationIgnored private var completionAttempted = false

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func start(services: WidgetBackgroundServices) {
        stopTasks()
        if phase == .endPrompt { phase = .active }
        promptStartedAt = nil
        suppressCloseUntilOpen = false
        completionAttempted = false
        self.services = services
        reconcileTask = Task { [weak self] in
            await self?.reconcile()
        }
    }

    /// Refresh once when the pill mounts. Calendar persists the handoff metadata
    /// before presenting this view, so an existing session does not need a
    /// process-wide polling loop to notice a newly attached recording.
    func reconcileOnPillMount() async {
        await reconcile()
    }

    func stop() {
        stopTasks()
        services = nil
    }

    private func stopTasks() {
        reconcileTask?.cancel(); reconcileTask = nil
        watchTask?.cancel(); watchTask = nil
        countdownTask?.cancel(); countdownTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        watchProcess?.terminate(); watchProcess = nil
        watchedBundleId = nil
    }

    private func string(_ key: String, services: WidgetBackgroundServices) async -> String? {
        guard let value = try? await services.storage.get(namespace: "meeting", key: key),
              case .string(let value) = value, !value.isEmpty else { return nil }
        return value
    }

    private func reconcile() async {
        guard let services else { return }

        let newTitle = await string("title", services: services)
        let newSourceApp = await string("source_app", services: services)
        let newBundleId = await string("source_bundle_id", services: services)
        let newRecordingDir = await string("recording_dir", services: services)
        let newStartedAt = await string("started_at", services: services).flatMap(parseISO8601)
        let newScheduledStart = await string("scheduled_start", services: services).flatMap(parseISO8601)
        let newScheduledEnd = await string("scheduled_end", services: services).flatMap(parseISO8601)
        let resolvedTitle = newTitle ?? "Meeting"
        let resolvedSourceApp = newSourceApp ?? "Meeting"

        // Reconciliation can run from both agent startup and pill mounting.
        // Avoid dirtying the observable model when persisted metadata has not
        // changed: each write otherwise invalidates the live pill's SwiftUI graph.
        if recordingDir != newRecordingDir { recordingDir = newRecordingDir }
        if startedAt != newStartedAt { startedAt = newStartedAt }
        if scheduledStart != newScheduledStart { scheduledStart = newScheduledStart }
        if scheduledEnd != newScheduledEnd { scheduledEnd = newScheduledEnd }
        if title != resolvedTitle { title = resolvedTitle }
        if sourceApp != resolvedSourceApp { sourceApp = resolvedSourceApp }
        if sourceBundleId != newBundleId {
            sourceBundleId = newBundleId
            sourceIcon = Self.icon(bundleId: newBundleId)
        }

        guard let recordingDir,
              let result = try? await services.shell.run(command: "meet42 record status --json"),
              result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let status = try? JSONDecoder().decode(TranscriptRecordStatusPayload.self, from: data)
        else { return }

        if status.recording, status.dir == recordingDir {
            if phase == .inactive || phase == .stopped {
                phase = .active
                try? await services.pill.present(widgetId: "transcript", sessionId: sessionId)
            }
            startWatchIfNeeded()
            startHeartbeatIfNeeded()
        } else if await string("ended_at", services: services).flatMap(parseISO8601) != nil {
            phase = .stopped
            cancelPrompt()
            stopWatch()
            stopHeartbeat()
            try? await services.pill.dismiss(widgetId: "transcript")
        }
    }

    private static func icon(bundleId: String?) -> NSImage? {
        guard let bundleId,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private func startWatchIfNeeded() {
        guard let bundleId = sourceBundleId, !bundleId.isEmpty,
              watchedBundleId != bundleId else { return }
        stopWatch()
        watchedBundleId = bundleId
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runWatchOnce(bundleId: bundleId)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopWatch() {
        watchTask?.cancel(); watchTask = nil
        watchProcess?.terminate(); watchProcess = nil
        watchedBundleId = nil
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil, let services else { return }
        heartbeatTask = Task {
            await services.activity.ping()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await services.activity.ping()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func runWatchOnce(bundleId: String) async {
        let invocation = transcriptMeet42Invocation(
            verb: "watch", extraArgs: ["--bundle-id", bundleId, "--json"]
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        watchProcess = process
        // A closed pipe simply ends the stream, letting the outer task respawn the watcher.
        for await line in transcriptAsyncLines(from: output.fileHandleForReading) {
            guard !Task.isCancelled else { break }
            await handleWatchLine(line)
        }
        if watchProcess === process { watchProcess = nil }
    }

    private func handleWatchLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else { return }
        switch event {
        case "call-open": micOpened()
        case "call-close": micClosed()
        default: break
        }
    }

    private func micOpened() {
        suppressCloseUntilOpen = false
        guard phase == .endPrompt else { return }
        cancelPrompt()
        phase = .active
    }

    private func micClosed() {
        guard phase == .active, !suppressCloseUntilOpen else { return }
        promptStartedAt = Date()
        phase = .endPrompt
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.stopMeeting(reason: "countdown")
        }
    }

    func stay() {
        guard phase == .endPrompt else { return }
        suppressCloseUntilOpen = true
        cancelPrompt()
        phase = .active
    }

    private func cancelPrompt() {
        countdownTask?.cancel(); countdownTask = nil
        promptStartedAt = nil
    }

    func stopMeeting(reason: String = "pill") async {
        guard let services, phase != .stopped, !completionAttempted else { return }
        completionAttempted = true
        cancelPrompt()
        await services.activity.ping()
        guard let recordingDir,
              let stop = try? await services.shell.run(
                  command: "meet42 record stop --dir \(transcriptShellQuote(recordingDir))"
              ), stop.exitCode == 0
        else {
            Meet42Trace.log("transcript", "recording-stop-failed", ["sessionId": sessionId, "reason": reason])
            return
        }
        stopHeartbeat()
        let endedAtJSON = transcriptShellQuote("\"\(isoNow())\"")
        guard let completion = try? await services.shell.run(
            command: "work42 storage set --session \(transcriptShellQuote(sessionId)) meeting/ended_at \(endedAtJSON)"
        ), completion.exitCode == 0 else {
            Meet42Trace.log("transcript", "completion-write-failed", ["sessionId": sessionId, "reason": reason])
            return
        }
        phase = .stopped
        stopWatch()
        try? await services.pill.dismiss(widgetId: "transcript")
        Meet42Trace.log("transcript", "recording-stopped", ["sessionId": sessionId, "reason": reason])
    }
}

@MainActor
private final class TranscriptMeetingRegistry {
    static let shared = TranscriptMeetingRegistry()
    private var models: [String: TranscriptMeetingModel] = [:]

    func model(for sessionId: String) -> TranscriptMeetingModel {
        if let model = models[sessionId] { return model }
        let model = TranscriptMeetingModel(sessionId: sessionId)
        models[sessionId] = model
        return model
    }
}

@Observable
@MainActor
private final class TranscriptMeetingAgent: WidgetBackgroundAgent {
    var headerLabels: [WidgetHeaderLabel] = []
    private var model: TranscriptMeetingModel?

    func start(services: WidgetBackgroundServices) {
        let model = TranscriptMeetingRegistry.shared.model(for: services.sessionId)
        self.model = model
        model.start(services: services)
    }

    func stop() {
        model?.stop()
        model = nil
    }
}

// MARK: - TranscriptWidget

@Observable
@MainActor
final class TranscriptWidget: Work42Widget, Work42WidgetPill, Work42WidgetBackground {

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
            // meet42-recording-lifecycle-rework s5: manual Record uses the
            // SAME session-agnostic primitive the calendar detection agent
            // uses. `fireTranscriptRecordStart` returning non-nil IS the
            // confirmation (it only returns once the daemon's pre-daemonize
            // stdout line appears, which only prints after the singleton
            // check passes — no separate confirm-poll needed, unlike the old
            // fire-and-forget version). `--manual` means no trigger call, so
            // no auto-stop — only this Stop intent (or the pill's) ends it.
            WidgetIntentSpec(
                name: "record",
                title: "Record",
                icon: "record.circle",
                brandColorHex: "#7C3AED",
                placement: [.actionArea],
                actionAreaStyle: .icon,
                isEnabled: { [weak self] in !(self?.isRecordingThisSession ?? false) },
                perform: { [weak self] in
                    guard let self, let svc = self.services, let sessionId = svc.sessionId else { return }
                    guard let started = await fireTranscriptRecordStart() else {
                        Meet42Trace.log("transcript", "manual-record-aborted", ["sessionId": sessionId])
                        return
                    }
                    Meet42Trace.log("transcript", "manual-record-started",
                        ["sessionId": sessionId, "recordingId": started.recordingId])

                    // Seed THIS session's pointer + the started_at workflow
                    // gate. A cross-process write into THIS widget's own
                    // session's "meeting" namespace — services.storage can't
                    // target it (restricted to the widget's own namespace,
                    // "transcript"), so this goes through the shelled CLI,
                    // which now resolves correctly via the WORK42_SESSION_ID
                    // env-match (meet42-recording-lifecycle-rework s6 fixed
                    // WidgetCommandRunner injecting the wrong directory for
                    // this exact lookup — no ArtifactRuntime registration
                    // needed here anymore).
                    let dirJSON = transcriptShellQuote("\"\(started.dir)\"")
                    let startedAtJSON = transcriptShellQuote("\"\(isoNow())\"")
                    _ = try? await svc.shell.run(
                        command: "work42 storage set --session \(transcriptShellQuote(sessionId)) meeting/recording_dir \(dirJSON)"
                    )
                    _ = try? await svc.shell.run(
                        command: "work42 storage set --session \(transcriptShellQuote(sessionId)) meeting/started_at \(startedAtJSON)"
                    )
                    await self.refreshRecordingState()
                    try? await svc.pill.present(widgetId: "transcript", sessionId: sessionId)
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
                    guard let self, let svc = self.services, let sessionId = svc.sessionId,
                          let recordingDir = await fetchRecordingDir(services: svc)
                    else { return }
                    // meet42 record stop just touches a marker file and
                    // returns immediately — the daemon honors it in ~1s now
                    // (s2's off-main stop-detection loop), safe via the
                    // bounded shell service. --dir, not --session-dir (s1
                    // dropped that flag — meet42 record is session-agnostic).
                    _ = try? await svc.shell.run(
                        command: "meet42 record stop --dir \(transcriptShellQuote(recordingDir))"
                    )
                    let endedAtJSON = transcriptShellQuote("\"\(isoNow())\"")
                    _ = try? await svc.shell.run(
                        command: "work42 storage set --session \(transcriptShellQuote(sessionId)) meeting/ended_at \(endedAtJSON)"
                    )
                    try? await svc.pill.dismiss(widgetId: "transcript")
                    Meet42Trace.log("transcript", "manual-stop", ["sessionId": sessionId])
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
            // The background agent is the lifecycle owner. This activation
            // reconciliation is only a fast path for a newly-mounted view.
            if self.isRecordingThisSession,
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
        micOptions = []
    }

    // MARK: - State refresh helpers

    /// Refresh the action-area controls from recording truth. Meeting close
    /// policy belongs to `TranscriptMeetingAgent`, not this UI poll.
    private func refreshRecordingState() async {
        guard let svc = services else { return }
        let snapshot = await fetchRecordingSnapshot(services: svc)
        isRecordingThisSession = snapshot.isRecordingThisSession
        recordingStartedAt = snapshot.startedAt
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

    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        TranscriptMeetingAgent()
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

// MARK: - RecordingAccessory

private struct RecordingAccessory: View {
    let services: SessionServices
    @State private var model: TranscriptMeetingModel

    init(services: SessionServices) {
        self.services = services
        _model = State(wrappedValue: TranscriptMeetingRegistry.shared.model(
            for: services.sessionId ?? "unbound"
        ))
    }

    private let warningColor = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
    private let overtimeColor = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)

    var body: some View {
        WidgetPillAccessoryShell(
            title: model.title,
            subtitle: subtitle,
            icon: WidgetPillAppIcon(image: model.sourceIcon, tint: meetingRecordingPurple),
            actionRow: {
                if model.phase == .endPrompt { promptRow } else { activeRow }
            },
            progressRail: {
                if model.phase == .endPrompt {
                    countdownBar
                } else if model.scheduledStart != nil, model.scheduledEnd != nil {
                    scheduleBar
                } else {
                    Color.clear
                }
            }
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.phase)
        .task { await model.reconcileOnPillMount() }
    }

    private var subtitle: String {
        model.phase == .endPrompt
            ? "\(model.sourceApp) · Microphone closed"
            : model.sourceApp
    }

    private var activeRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let schedule = scheduleState(at: context.date)
            HStack(spacing: 8) {
                Text(schedule.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(schedule.labelColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                openSessionButton
                stopControl
            }
            .frame(height: 32)
        }
    }

    private var promptRow: some View {
        HStack(spacing: 10) {
            TimelineView(.animation) { ctx in
                Text("Auto-stopping in \(countdownSeconds(at: ctx.date))s")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(meetingRecordingPurpleLight)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Stay") { model.stay() }
                .buttonStyle(WidgetPillActionButtonStyle())
            Button("Stop") { Task { await model.stopMeeting(reason: "prompt") } }
                .buttonStyle(WidgetPillActionButtonStyle(emphasis: .primary, tint: meetingRecordingPurple))
        }
        .frame(height: 32)
    }

    private var countdownBar: some View {
        TimelineView(.animation) { ctx in
            let frac = countdownFraction(at: ctx.date)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08))
                Rectangle()
                    .fill(meetingRecordingPurple)
                    .frame(width: max(0, WidgetPillAccessoryMetrics.width * frac))
                    .shadow(color: meetingRecordingPurple.opacity(0.7), radius: 4)
            }
            .frame(height: WidgetPillAccessoryMetrics.progressHeight)
        }
    }

    private var scheduleBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let schedule = scheduleState(at: context.date)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08))
                Rectangle()
                    .fill(schedule.railColor)
                    .frame(width: max(0, WidgetPillAccessoryMetrics.width * schedule.remainingFraction))
            }
            .frame(height: WidgetPillAccessoryMetrics.progressHeight)
        }
    }

    private var openSessionButton: some View {
        Button {
            guard let sessionId = services.sessionId else { return }
            Task {
                try? await services.intents.execute(
                    id: "global.openLink",
                    params: ["url": .string("work42://session/\(sessionId)")]
                )
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward.app")
                Text("Open Session")
            }
        }
        .buttonStyle(WidgetPillActionButtonStyle())
        .help("Open meeting session")
    }

    @ViewBuilder
    private var stopControl: some View {
        if let started = model.startedAt {
            TimelineView(.periodic(from: started, by: 1)) { ctx in
                stopButton(elapsed: max(0, Int(ctx.date.timeIntervalSince(started))))
            }
        } else {
            stopButton(elapsed: 0)
        }
    }

    private func stopButton(elapsed: Int) -> some View {
        Button(action: { Task { await model.stopMeeting() } }) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .medium))
                Text(Self.timeString(elapsed))
                    .monospacedDigit()
            }
        }
        .buttonStyle(WidgetPillActionButtonStyle(emphasis: .primary, tint: meetingRecordingPurple))
        .help("Stop recording")
    }

    private static func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    private func countdownFraction(at date: Date) -> CGFloat {
        guard let start = model.promptStartedAt else { return 0 }
        let remaining = max(0, 10 - date.timeIntervalSince(start))
        return CGFloat(remaining / 10)
    }

    private func countdownSeconds(at date: Date) -> Int {
        guard let start = model.promptStartedAt else { return 0 }
        let remaining = max(0, 10 - date.timeIntervalSince(start))
        return max(1, Int(ceil(remaining)))
    }

    private struct ScheduleState {
        let label: String
        let labelColor: Color
        let railColor: Color
        let remainingFraction: CGFloat
    }

    private func scheduleState(at date: Date) -> ScheduleState {
        guard let start = model.scheduledStart, let end = model.scheduledEnd, end > start else {
            return ScheduleState(
                label: "In Progress",
                labelColor: .white.opacity(0.65),
                railColor: .clear,
                remainingFraction: 0
            )
        }
        let remaining = end.timeIntervalSince(date)
        if remaining <= 0 {
            let minutes = max(1, Int(ceil(abs(remaining) / 60)))
            return ScheduleState(
                label: "Over by \(minutes) min",
                labelColor: overtimeColor,
                railColor: .clear,
                remainingFraction: 0
            )
        }
        let minutes = max(1, Int(ceil(remaining / 60)))
        let isWarning = remaining <= 5 * 60
        let fraction = min(1, max(0, remaining / end.timeIntervalSince(start)))
        return ScheduleState(
            label: "\(minutes) min left",
            labelColor: isWarning ? warningColor : meetingRecordingPurpleLight,
            railColor: isWarning ? warningColor : meetingRecordingPurple,
            remainingFraction: CGFloat(fraction)
        )
    }
}

// MARK: - Widget entry-point ABI

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
