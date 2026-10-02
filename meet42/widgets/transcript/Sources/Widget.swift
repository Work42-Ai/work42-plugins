// Widget.swift — meet42's Transcript widget (meet42-plugin-conversion, s14).
//
// The most complex meet42 widget: a TILE (conversation.jsonl → chat bubbles),
// a stateful PILL (RECORDING / ENDED / idle recording accessory), AND a
// BACKGROUND AGENT that drives capture from the calendar widget's autostart
// handoff and watches for the meeting ending.
//
// Faithful port of three app surfaces into a plugin widget that links ONLY
// Work42WidgetKit + Work42UI:
//
//   • Tile      — Work42App/Meetings/TranscriptWidgetView. Reads
//                 `<dir>/conversation.jsonl` (+ optional `speakers.json`) and
//                 renders each utterance as a Work42UI `ChatBubble`
//                 (You = trailing/accent, Them = leading/speaker-hue once
//                 matched else neutral, unknown = leading/neutral). The
//                 Flow42Core `TranscriptStore` parser + `FileWatcher` are
//                 reimplemented locally (no Flow42Core import).
//   • Pill      — Work42App/Dictation/EventSessionAccessory, RECORDING +
//                 ENDED states only (+ a plain idle). The DETECTED state is
//                 dropped — the calendar widget (s16) owns it. Visuals kept:
//                 purple #7C3AED, the Stop capsule with a live monospaced
//                 `M:SS` timer, the "Auto-stopping in Ns" ended row + bar.
//   • Agent     — the autostart handoff (calendar widget sets
//                 `meeting/autostart`) → `meet42 record start` → write
//                 `meeting/started_at` → present the RECORDING pill; then a
//                 cancellable mic poll that, on an open→close transition,
//                 stops capture, writes `meeting/ended_at`, dismisses the pill.
//
// CRITICAL: `storageNamespace` is "meeting" so VIEW-SIDE `SessionServices.storage`
// writes (the manual Record/Stop action-area intents, the pill's Stop control)
// land at `meeting/started_at`/`meeting/ended_at` — the workflow gates. This
// does NOT extend to the BACKGROUND AGENT below: `WidgetBackgroundHost.makeServices`
// hardcodes its storage to the widget's own slug ("transcript") regardless of
// `storageNamespace`, so `TranscriptAgent` writes `meeting/started_at`/`ended_at`
// explicitly via `work42 storage set` (shelled), not `WidgetBackgroundServices.storage.set`.

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

/// A storage value is "truthy" when it is a non-empty / non-zero affirmative —
/// covers `.bool(true)`, any non-zero number, and "1"/"true"/"yes" strings.
private func isTruthy(_ v: WidgetJSONValue?) -> Bool {
    switch v {
    case .bool(let b): return b
    case .number(let n): return n != 0
    case .string(let s):
        let l = s.trimmingCharacters(in: .whitespaces).lowercased()
        return l == "1" || l == "true" || l == "yes"
    default: return false
    }
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
final class TranscriptWidget: Work42Widget, Work42WidgetPill, Work42WidgetBackground {

    let id = "transcript"
    let title = "Transcript"
    let icon = "waveform"

    /// CRITICAL: writes land in the `meeting/*` namespace (not `transcript/*`),
    /// so `storage.set(key: "started_at")` → `meeting/started_at` (the workflow
    /// "In Meeting" gate) and `storage.set(key: "ended_at")` → `meeting/ended_at`.
    var storageNamespace: String? { "meeting" }

    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 280, height: 220) }

    // MARK: - Recording state (drives action-area intent isEnabled / labels)

    /// True when `meeting/started_at` is set AND `meeting/ended_at` is unset.
    /// Drives the `record` intent (hidden while true) and the `stop` intent
    /// (visible/enabled while true). Observed by the host at render time.
    private(set) var isRecordingThisSession: Bool = false

    /// Parsed `meeting/started_at`; drives the stop intent's live mm:ss timer.
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
                          let dir = svc.worktreePath else { return }
                    _ = try? await svc.shell.run(
                        command: "meet42 record start --session-dir \"\(dir)\""
                    )
                    try? await svc.storage.set(
                        key: "started_at", value: .string(isoNow())
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
                          let dir = svc.worktreePath else { return }
                    _ = try? await svc.shell.run(
                        command: "meet42 record stop --session-dir \"\(dir)\""
                    )
                    try? await svc.storage.set(
                        key: "ended_at", value: .string(isoNow())
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
            while !Task.isCancelled {
                await self?.refreshRecordingState()
                await self?.refreshMicOptions()
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

    /// Poll `meeting/started_at` and `meeting/ended_at` to derive
    /// `isRecordingThisSession` and `recordingStartedAt`.
    private func refreshRecordingState() async {
        guard let svc = services else { return }
        let started = try? await svc.storage.get(namespace: "meeting", key: "started_at")
        let ended   = try? await svc.storage.get(namespace: "meeting", key: "ended_at")
        var startDate: Date? = nil
        if case .string(let s) = started { startDate = parseISO8601(s) }
        let hasEnded: Bool
        if case .string(_) = ended { hasEnded = true } else { hasEnded = false }
        recordingStartedAt = startDate
        isRecordingThisSession = startDate != nil && !hasEnded
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

    // MARK: Work42WidgetBackground

    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        TranscriptAgent()
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

    var body: some View {
        // Register both watchers as dependencies so the body re-runs on change.
        let _ = conversationWatcher.version
        let _ = speakersWatcher.version
        let dir = services.worktreePath
        let lines = dir.map { parseConversation(sessionDir: $0) } ?? []
        let speakers = dir.map { loadSpeakers(sessionDir: $0) } ?? [:]

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
        .onAppear {
            if let dir {
                conversationWatcher.watch(conversationPath(sessionDir: dir))
                speakersWatcher.watch(speakersPath(sessionDir: dir))
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

    private func refresh() async {
        let started = try? await services.storage.get(namespace: "meeting", key: "started_at")
        let ended = try? await services.storage.get(namespace: "meeting", key: "ended_at")
        var startDate: Date?
        if case .string(let s) = started { startDate = parseISO8601(s) }
        var endDate: Date?
        if case .string(let s) = ended { endDate = parseISO8601(s) }
        startedAt = startDate
        endedAt = endDate
        if endDate != nil {
            state = .ended
        } else if startDate != nil {
            state = .recording
        } else {
            state = .idle
        }
    }

    /// Stop capture now: `meet42 record stop` + write ended_at + dismiss the
    /// pill. Reused by both the RECORDING Stop and the ENDED Stop controls.
    func stopRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.services.shell.run(command: "meet42 record stop --session-dir \"$(pwd)\"")
            try? await self.services.storage.set(key: "ended_at", value: .string(isoNow()))
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

// MARK: - TranscriptAgent (background — drives capture)

/// The headless agent for one (session × transcript-widget). On the calendar
/// widget's autostart handoff it starts capture, marks `meeting/started_at`,
/// and floats the RECORDING pill; then it polls the mic and, on an open→close
/// transition after a start, stops capture, marks `meeting/ended_at`, and
/// dismisses the pill.
///
/// Mic-watch caveat (see report + SKILL.md): `meet42 watch` is a long-lived
/// blocking stream and `WidgetShellService.run` is buffered request/response —
/// a bare `watch` would never return. So the loop runs a *bounded* `watch`
/// (kill after ~2s) each cycle as a single-shot mic-level probe: a freshly
/// started `watch` emits `mic-open` within its first poll iff the default input
/// is currently running, and emits nothing when it is closed. This is
/// cancellable and never blocks the agent. (`meet42 mics --json` lists DEVICES,
/// not running-state, so it cannot serve as the probe.)
@Observable
@MainActor
final class TranscriptAgent: WidgetBackgroundAgent {

    var headerLabels: [WidgetHeaderLabel] { [] }

    @ObservationIgnored private var task: Task<Void, Never>?

    func start(services s: WidgetBackgroundServices) {
        task?.cancel()
        task = Task { @MainActor in
            // Let the view mount before the first storage/shell touch.
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // 1. Autostart handoff — the calendar widget set meeting/autostart.
            if isTruthy(try? await s.storage.get(namespace: "meeting", key: "autostart")) {
                // Only start if not already started (idempotent across restarts).
                let alreadyStarted = (try? await s.storage.get(namespace: "meeting", key: "started_at")) != nil
                if !alreadyStarted {
                    _ = try? await s.shell.run(command: "meet42 record start --session-dir \"$(pwd)\"")
                    // `storage.set` can only write into THIS widget's own
                    // ("transcript") namespace — it has no namespace parameter.
                    // The workflow gate and this agent's own isRecording/ended
                    // checks read `meeting/*`, so this MUST go through the
                    // shell (`work42 storage set meeting/started_at ...`), the
                    // same cross-namespace-write pattern the calendar widget
                    // uses for `meeting/autostart`.
                    let startedAtJSON = transcriptShellQuote("\"\(isoNow())\"")
                    _ = try? await s.shell.run(command: "work42 storage set meeting/started_at \(startedAtJSON)")
                    try? await s.pill.present(widgetId: "transcript", sessionId: s.sessionId)
                }
            }

            // 2. Mic poll — detect the recording's open→close transition.
            var sawOpen = false
            while !Task.isCancelled {
                // Already ended → nothing to watch.
                if (try? await s.storage.get(namespace: "meeting", key: "ended_at")).flatMap({ $0 }) != nil {
                    break
                }
                let isRecording = (try? await s.storage.get(namespace: "meeting", key: "started_at")).flatMap({ $0 }) != nil
                if isRecording {
                    let open = await Self.micIsOpen(shell: s.shell)   // ~2s bounded probe
                    if open {
                        sawOpen = true
                    } else if sawOpen {
                        // open → close: stop, advance to Summary, dismiss the pill.
                        _ = try? await s.shell.run(command: "meet42 record stop --session-dir \"$(pwd)\"")
                        let endedAtJSON = transcriptShellQuote("\"\(isoNow())\"")
                        _ = try? await s.shell.run(command: "work42 storage set meeting/ended_at \(endedAtJSON)")
                        try? await s.pill.dismiss(widgetId: "transcript")
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Single-shot mic-level probe: run a fresh `meet42 watch` bounded to ~2s
    /// and report whether it emitted `mic-open` (the default input is running).
    /// Never blocks — the subprocess is killed after the window.
    private static func micIsOpen(shell: any WidgetShellService) async -> Bool {
        let command = "meet42 watch & _w=$!; sleep 2; kill $_w 2>/dev/null; wait $_w 2>/dev/null; true"
        guard let result = try? await shell.run(command: command) else { return false }
        return result.stdout.contains("mic-open")
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
