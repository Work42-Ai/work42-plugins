// MeetingTranscriptionEngine.swift — Live transcription using macOS 26 SpeechTranscriber.
//
// Subtask 6 of quiet-lark: "Live transcription: 2x SpeechTranscriber -> conversation.jsonl"
// Subtask 7 of quiet-lark: "Fixture-injection seam for the transcription pipeline"
//
// WHAT THIS FILE DOES
// -------------------
// Wires two SpeechAnalyzer/SpeechTranscriber sessions into MeetingTranscriptionService,
// one per audio channel:
//
//   mic / .microphone  → SpeechTranscriber (You)  → "You" lines in conversation.jsonl
//   system / .audio    → SpeechTranscriber (Them) → "Them" lines in conversation.jsonl
//
// Each channel has its own SpeechAnalyzer (one analyzer = one audio stream) fed via
// an AsyncStream<AnalyzerInput>. Two separate audio channels → two separate analyzer
// sessions. A single SpeechAnalyzer with two inputs is not applicable — each SpeechAnalyzer
// processes one coherent audio timeline.
//
// CMSampleBuffer → AnalyzerInput CONVERSION
// ------------------------------------------
// SCStream delivers audio as CMSampleBuffer containing LPCM audio (16 kHz mono as
// configured in RecordingCore.buildStreamConfiguration). The conversion path is:
//
//   CMSampleBuffer
//     → AVAudioFormat  (via CMFormatDescriptionRef)
//     → AVAudioPCMBuffer (copy via CMSampleBufferCopyPCMDataIntoAudioBufferList into the
//                          buffer's own AudioBufferList)
//     → AVAudioConverter (lazy, resamples to the analyzer's preferred format if needed)
//     → AnalyzerInput(buffer: pcmBuffer, bufferStartTime: presentationTimeStamp)
//
// The analyzer's target format is obtained via:
//   SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:considering:)
// An AVAudioConverter is created lazily once per session.
//
// MODEL AVAILABILITY / FAIL-LOUD
// --------------------------------
// SpeechTranscriber.isAvailable is a fast synchronous check (macOS 26 API).
// AssetInventory.status(forModules:) is the async check for the on-device model asset.
// If the model is unavailable or not downloaded, start() throws
// TranscriptionEngineError.speechModelUnavailable with a clear recovery message.
//
// CONCURRENCY
// -----------
// MeetingTranscriptionEngine is @MainActor. CMSampleBuffer handler closures fire on
// SCStream's internal queue (nonisolated) and route buffers to the active
// ChannelTranscriber via TranscriberHolder (NSLock-guarded nonisolated properties).
// ChannelTranscriber is @available(macOS 26.0, *) and uses nonisolated(unsafe) for
// state written once in prepare() and then read in ingest() on the SCStream queue.
//
// CONVERSATION.JSONL SHAPE (AC4)
// -------------------------
//   { "ts": "<ISO8601 with fractional seconds>", "speaker": "You"|"Them", "text": "<string>" }
// One line per FINALIZED utterance. Volatile (in-progress) results are discarded.
//
// ─────────────────────────────────────────────────────────────────────────────
// FIXTURE-INJECTION SEAM (AC21, subtask 7)
// ─────────────────────────────────────────────────────────────────────────────
//
// ENV VAR:  WORK42_MEETING_FIXTURE_WAV=<path>
//
// When set, the transcription pipeline consumes the specified WAV file INSTEAD
// of opening the live SCStream. No live meeting and no SCStream / screen-
// recording permission is needed. The result is a real conversation.jsonl in
// the session directory, identical in shape to the live path.
//
// EXPECTED WAV FORMAT — two options (both accepted):
//
//   Option A — Stereo WAV (preferred):
//     • 2-channel (stereo) WAV, any sample rate (16 kHz recommended)
//     • Left  channel → "You"  (mic / local speaker)
//     • Right channel → "Them" (system audio / remote participants)
//     • The seam reads both channels and routes each to the correct
//       ChannelTranscriber, resampling to the analyzer's preferred format.
//
//   Option B — Two mono files (alternative):
//     • Set WORK42_MEETING_FIXTURE_WAV=/path/to/you.wav:/path/to/them.wav
//       (colon-separated, exactly two paths)
//     • First path  → "You"  channel
//     • Second path → "Them" channel
//     • Both files must be readable WAV or Core Audio-supported formats.
//
// BEHAVIOUR:
//   • The seam is INERT when WORK42_MEETING_FIXTURE_WAV is not set (zero
//     effect on the live path — the env var is only checked inside start()).
//   • MeetingTranscriptionService.start() is NOT called in fixture mode
//     (no RecordingCore, no SCStream). The fixture drives the transcriberss
//     directly via the ingestPCM(_:at:) method.
//   • Buffers are fed in CHUNK_SIZE-frame chunks separated by a small sleep
//     (DEFAULT_CHUNK_FRAMES / sampleRate) so the SpeechAnalyzer receives
//     a realistic streaming cadence rather than one enormous buffer.
//   • stop() finalizes transcription as normal.
//
// GENERATING A FIXTURE WAV (recipe):
//   # Stereo WAV: left=you, right=them, 16 kHz
//   sox you_mono.wav them_mono.wav \
//       --combine merge fixture_stereo.wav \
//       rate 16000 channels 2
//
//   # Or with ffmpeg:
//   ffmpeg -i you_mono.wav -i them_mono.wav \
//       -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo[a]" \
//       -map "[a]" fixture_stereo.wav
// ─────────────────────────────────────────────────────────────────────────────

@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import Speech

// MARK: - ConversationLine

/// One line in conversation.jsonl. Named attribution is the responsibility of the
/// end-of-meeting pass (subtask 16); here we only write generic You/Them.
/// nonisolated so encoding works from any actor context.
private nonisolated struct ConversationLine: Encodable {
    let ts: String       // ISO8601 with fractional seconds
    let speaker: String  // "You" or "Them"
    let text: String
    /// Audio-timeline interval (seconds, relative to when this session's
    /// "Them"-channel transcription began) when these words were actually
    /// spoken — as opposed to `ts`, which is the wall-clock moment the line
    /// FINALIZED and lags real speech by several seconds. Sourced from the
    /// SpeechTranscriber result's per-run `audioTimeRange` attribute
    /// (requires `.audioTimeRange` in `attributeOptions`, see
    /// ChannelTranscriber.init). nil when the channel doesn't track audio
    /// time (the "You" channel today) or when a given result carried no
    /// audioTimeRange attribute (an intermittent gap in the framework).
    let audioStartSeconds: Double?
    let audioEndSeconds: Double?
    /// Stable identifier minted at append time, present on every line going
    /// forward. Lets `ConversationLog.rewriteSpeakerLabel(lineId:to:)` target
    /// exactly one line for correction (live diarization tagging, the
    /// meeting-end attribution pass, or a manual "who is this?" fix) without
    /// relying on line order/text matching. Lines written before this field
    /// existed simply have no "lineId" key — readers must tolerate that.
    let lineId: String
    /// Live speaker-diarization label ("Voice A"/"Voice B"/... from
    /// SpeakerDiarizationService, or a real name once the meeting-end
    /// attribution pass or a manual correction resolves it). Only set for
    /// "Them" lines where a diarized segment overlapped this line's audio
    /// interval by the time it finalized — nil otherwise (falls back to the
    /// plain `speaker` field, i.e. today's behavior).
    let speakerLabel: String?
}

// MARK: - SystemEventRectPayload

/// Rect payload for a system-event JSONL line.  Encodes as { x, y, width, height }.
/// nonisolated so it can be encoded from any actor context.
nonisolated struct SystemEventRectPayload: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width  = Double(rect.size.width)
        height = Double(rect.size.height)
    }
}

// MARK: - SystemEventLine

/// A system-event JSONL line.  Shape (AC8, AC10):
///   { "ts": <ISO8601>, "type": "system_event", "event": "screen_highlight",
///     "image": <relative path>, "app": <name>, "bundle_id": <id>,
///     "ocr_text": <text>, "rect": {x,y,width,height} }
///
/// The `type` field distinguishes it from legacy speaker lines which have
/// no `type` field (AC11 back-compat: missing `type` => speaker line).
nonisolated struct SystemEventLine: Encodable {
    let ts: String
    let type: String       // always "system_event"
    let event: String      // always "screen_highlight"
    let image: String?     // relative path inside session dir
    let app: String?       // frontmost app localised name
    let bundle_id: String? // frontmost app bundle id
    let ocr_text: String?  // Vision OCR fullText
    let rect: SystemEventRectPayload
}

// MARK: - ConversationLog

/// Append-only writer for <sessionDir>/conversation.jsonl.
/// Pattern mirrors SessionTranscriptLog.append: createDirectory + FileHandle seekToEnd.
/// Actor-isolated so multiple concurrent result tasks append safely without interleaving.
actor ConversationLog {
    private let fileURL: URL
    private let sessionDir: URL
    private let encoder: JSONEncoder
    private let iso: ISO8601DateFormatter

    init(sessionDir: URL) {
        self.sessionDir = sessionDir
        self.fileURL = sessionDir.appendingPathComponent("conversation.jsonl")
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = enc
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso = fmt
    }

    /// Append a finalized line to conversation.jsonl.
    /// Creates the file (and parent directory) if needed, then seeks to end.
    ///
    /// - Parameters:
    ///   - audioStartSeconds/audioEndSeconds: the audio-timeline interval
    ///     (seconds since this channel's transcription began) when the
    ///     words were actually spoken. Pass nil for channels/results that
    ///     don't track this (e.g. "You" today).
    ///   - speakerLabel: the live diarization label for this line ("Voice A"
    ///     etc.), when a diarized segment already overlapped this line's
    ///     audio interval at finalize time. nil otherwise — the line can
    ///     still be labeled later via `rewriteSpeakerLabel(lineId:to:)`.
    @discardableResult
    func append(
        speaker: String,
        text: String,
        audioStartSeconds: Double? = nil,
        audioEndSeconds: Double? = nil,
        speakerLabel: String? = nil
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let ts = iso.string(from: Date())
        let lineId = UUID().uuidString
        let line = ConversationLine(
            ts: ts,
            speaker: speaker,
            text: trimmed,
            audioStartSeconds: audioStartSeconds,
            audioEndSeconds: audioEndSeconds,
            lineId: lineId,
            speakerLabel: speakerLabel
        )

        do {
            var data = try encoder.encode(line)
            data.append(0x0A) // newline

            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            Log.info("[ConversationLog] appended \(speaker): \(trimmed.prefix(80))")
            return lineId
        } catch {
            Log.info("[ConversationLog] append error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Patch the `speakerLabel` field on one existing line, identified by
    /// its stable `lineId` (minted at append time). Read-modify-atomic-
    /// rewrite of the whole file — safe because this actor is the sole
    /// writer of conversation.jsonl, and the actor serializes calls, so no
    /// append can interleave with a rewrite's read+write.
    ///
    /// Parses each raw line with `JSONSerialization` (mirroring
    /// `TranscriptStore.TranscriptLine.init?(jsonString:)`'s tolerant
    /// approach) rather than decoding through `ConversationLine` (which is
    /// `Encodable`-only) — this also means `system_event` lines (no
    /// `lineId` key) and any line written before this field existed pass
    /// through byte-for-byte untouched.
    ///
    /// Used by the meeting-end attribution pass (subtask .6) and manual
    /// "who is this?" corrections in the transcript UI (subtask .5). No-op
    /// (logs) if `lineId` isn't found.
    func rewriteSpeakerLabel(lineId: String, to newLabel: String) {
        rewriteSpeakerLabels([lineId: newLabel])
    }

    /// Batch variant: apply many lineId → speakerLabel patches in ONE
    /// read-modify-atomic-rewrite pass. A `nil` value CLEARS the line's
    /// speakerLabel (used when a re-cluster pass demotes a previously-labeled
    /// voice to an unlabeled singleton — see DiarizationWorker's conservative
    /// labeling rule). Per-line single rewrites would be O(n²) file churn at
    /// the diarizer's per-window back-patch cadence and would thrash the
    /// transcript tile's 500 ms FileWatcher; one pass per window keeps both
    /// costs flat.
    func rewriteSpeakerLabels(_ updates: [String: String?]) {
        guard !updates.isEmpty else { return }
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            Log.info("[ConversationLog] rewriteSpeakerLabels: could not read \(fileURL.path)")
            return
        }

        var patched = 0
        let rewrittenLines: [String] = raw.components(separatedBy: "\n").map { rawLine in
            guard let data = rawLine.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lineId = obj["lineId"] as? String,
                  let update = updates[lineId]
            else {
                return rawLine
            }
            if let newLabel = update {
                obj["speakerLabel"] = newLabel
            } else {
                obj.removeValue(forKey: "speakerLabel")
            }
            guard let patchedData = try? JSONSerialization.data(withJSONObject: obj),
                  let patchedString = String(data: patchedData, encoding: .utf8) else {
                return rawLine
            }
            patched += 1
            return patchedString
        }

        guard patched > 0 else {
            Log.info("[ConversationLog] rewriteSpeakerLabels: no matching lineIds among \(updates.count) updates")
            return
        }

        do {
            try rewrittenLines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            Log.info("[ConversationLog] rewriteSpeakerLabels: patched \(patched)/\(updates.count) lines")
        } catch {
            Log.info("[ConversationLog] rewriteSpeakerLabels write error: \(error.localizedDescription)")
        }
    }

    /// Append a system-event entry for a screen highlight to conversation.jsonl.
    ///
    /// Copies the PNG from `sourcePath` into the session directory and records a
    /// relative image path so the entry is self-contained alongside
    /// `conversation.jsonl` (AC8, AC10).
    ///
    /// - Parameters:
    ///   - sourcePath: Absolute path to the captured region PNG.
    ///   - appName:   Frontmost app name at capture time.
    ///   - bundleId:  Frontmost app bundle id at capture time.
    ///   - ocrText:   Vision OCR `fullText` for the captured region.
    ///   - rect:      Captured rect in global Quartz screen coordinates.
    func appendSystemEvent(
        sourcePath: String,
        appName: String?,
        bundleId: String?,
        ocrText: String?,
        rect: CGRect
    ) {
        let fm = FileManager.default

        // Copy the PNG into the session dir so the log and image are co-located.
        // Use a timestamped name to avoid collisions if multiple highlights are
        // captured in the same session.
        let ts = iso.string(from: Date())
        var relativeImagePath: String? = nil
        let srcURL = URL(fileURLWithPath: sourcePath)
        let ext = srcURL.pathExtension.isEmpty ? "png" : srcURL.pathExtension
        let destName = "highlight-\(ts.replacingOccurrences(of: ":", with: "-")).\(ext)"
        let destURL  = sessionDir.appendingPathComponent(destName)

        do {
            // Ensure session directory exists before copying.
            if !fm.fileExists(atPath: sessionDir.path) {
                try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: srcURL.path) {
                try fm.copyItem(at: srcURL, to: destURL)
                relativeImagePath = destName
                Log.info("[ConversationLog] copied highlight image → \(destName)")
            } else {
                relativeImagePath = nil
                Log.info("[ConversationLog] highlight source not found: \(sourcePath)")
            }
        } catch {
            relativeImagePath = nil
            Log.info("[ConversationLog] highlight copy error: \(error.localizedDescription)")
        }

        // Build the JSONL line.
        let line = SystemEventLine(
            ts: ts,
            type: "system_event",
            event: "screen_highlight",
            image: relativeImagePath,
            app: appName,
            bundle_id: bundleId,
            ocr_text: ocrText,
            rect: SystemEventRectPayload(rect)
        )

        do {
            var data = try encoder.encode(line)
            data.append(0x0A) // newline

            let dir = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            Log.info("[ConversationLog] appended system_event screen_highlight (app: \(appName ?? "?"))")
        } catch {
            Log.info("[ConversationLog] appendSystemEvent error: \(error.localizedDescription)")
        }
    }
}

// MARK: - TranscriptionEngineError

/// Typed error for the transcription engine — fail loud with clear recovery guidance.
enum TranscriptionEngineError: Error, LocalizedError {
    /// SpeechTranscriber is not available on this device/OS.
    case speechModelUnavailable(String)
    /// The model is not installed yet BUT a background download has been
    /// triggered — a soft, transient state (distinct from the hard
    /// `speechModelUnavailable`, which is reserved for unsupported hardware /
    /// macOS < 26). Surfaces as the soft "Downloading speech model…" notice.
    case speechModelDownloading(String)
    /// SpeechAnalyzer failed to prepare (e.g., model not downloaded).
    case analyzerPreparationFailed(underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .speechModelUnavailable(let msg):
            return "Speech model unavailable: \(msg)"
        case .speechModelDownloading(let msg):
            return "Downloading speech model: \(msg)"
        case .analyzerPreparationFailed(let e):
            return "SpeechAnalyzer preparation failed: \(e.localizedDescription). " +
                   "Ensure the on-device speech model is downloaded in " +
                   "Settings → General → Language & Region → Speech Recognition."
        }
    }
}

// MARK: - ChannelTranscriber

/// Manages one SpeechAnalyzer + SpeechTranscriber feeding from an AsyncStream<AnalyzerInput>.
/// Created fresh for each meeting capture session (start/stop cycle).
///
/// Two ChannelTranscribers run concurrently — one for mic (You), one for system audio (Them).
/// Each has its own SpeechAnalyzer because each processes a distinct audio timeline.
///
/// Concurrency discipline:
///   - `prepare()` and `start()` are called from @MainActor context before ingest() fires.
///   - `ingest(_:)` is nonisolated, called on the SCStream queue.
///   - `nonisolated(unsafe)` fields (continuation, converter, analyzerFormat) are:
///     - Written once in init()/prepare() before ingest() can be called.
///     - Read-only in ingest() afterward. No concurrent writes → safe.
@available(macOS 26.0, *)
final class ChannelTranscriber: @unchecked Sendable {

    // MARK: - Properties

    let speaker: String  // "You" or "Them"

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer

    // Written in init(), read in ingest(). @unchecked Sendable + nonisolated(unsafe).
    private nonisolated(unsafe) var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let stream: AsyncStream<AnalyzerInput>

    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    private let log: ConversationLog

    // Written once in prepare() before any ingest() calls; read in ingest() on SCStream queue.
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var analyzerFormat: AVAudioFormat?

    // MARK: - Init

    init(speaker: String, log: ConversationLog) {
        self.speaker = speaker
        self.log = log

        // Use .transcription preset's transcriptionOptions/reportingOptions verbatim
        // (raw words, minimal formatting — no punctuation, no emoji, no etiquette
        // replacements) but additionally request the .audioTimeRange result
        // attribute, so each finalized result's runs carry a CMTimeRange for when
        // the words were actually spoken (see ConversationLine.audioStartSeconds).
        // SpeechTranscriber has no preset+attributeOptions initializer overload —
        // Apple's documented pattern for extending a preset is to union its own
        // transcriptionOptions/reportingOptions/attributeOptions with the extra
        // option(s) via the explicit initializer, which is what this does.
        let basePreset = SpeechTranscriber.Preset.transcription
        self.transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: basePreset.transcriptionOptions,
            reportingOptions: basePreset.reportingOptions,
            attributeOptions: basePreset.attributeOptions.union([.audioTimeRange])
        )

        var capturedContinuation: AsyncStream<AnalyzerInput>.Continuation?
        self.stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .unbounded) { cont in
            capturedContinuation = cont
        }
        self.continuation = capturedContinuation

        // SpeechAnalyzer with this transcriber module.
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    // MARK: - Model availability check

    /// Check that the SpeechTranscriber model is available and installed.
    /// Fail-loud: throws `TranscriptionEngineError.speechModelUnavailable` with
    /// a clear recovery message if the model is not ready.
    ///
    /// Gates "installed" on `SpeechTranscriber.installedLocales` — a
    /// persistent, on-disk signal — rather than `AssetInventory.status()`,
    /// whose `.installed` case is reservation-linked: on macOS 26, running a
    /// transcription auto-reserves the locale and flips status to
    /// `.installed`, but the reservation lapses after idle/eviction and
    /// status drops back to `.supported` even though the model is still on
    /// disk (`installedLocales` is unchanged) — the root cause of a
    /// genuinely-installed model intermittently surfacing the "Speech model
    /// isn't installed" toast. Never constructs a throwaway `SpeechTranscriber`
    /// probe on this hot path (called every meeting/dictation start) — only
    /// the COLD "genuinely not installed" branch below needs one, since
    /// `assetInstallationRequest` requires a module instance.
    static func checkModelAvailability() async throws {
        // Fast availability gate routes through the unified Permissions catalog
        // (`Permission.speechModel.status`) so the "is on-device speech
        // available" answer is consistent app-wide. On macOS 26 the catalog
        // maps `SpeechTranscriber.isAvailable` → `.authorized` — hardware/OS
        // capability only, not per-locale install state (checked next).
        guard Permission.speechModel.status == .authorized else {
            throw TranscriptionEngineError.speechModelUnavailable(
                "SpeechTranscriber.isAvailable is false on this device. " +
                "Requires macOS 26+ with a supported Neural Engine. " +
                "Check System Settings → General → Language & Region → Speech Recognition."
            )
        }

        let locale = Locale.current
        let installedLocales = await SpeechTranscriber.installedLocales
        guard installedLocales.contains(where: { $0.isEquivalent(to: locale) }) else {
            // Genuinely absent from disk — trigger a background download.
            // The terminal "not installed" toast fires ONLY on this path.
            Log.info("[ChannelTranscriber] Speech model not installed — triggering download")
            let probe = SpeechTranscriber(locale: locale, preset: .transcription)
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    Task {
                        do {
                            try await request.downloadAndInstall()
                            Log.info("[ChannelTranscriber] Speech model download complete")
                        } catch {
                            Log.info("[ChannelTranscriber] Speech model download failed: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                Log.info("[ChannelTranscriber] assetInstallationRequest error: \(error.localizedDescription)")
            }
            throw TranscriptionEngineError.speechModelDownloading(
                "On-device speech model is not installed yet. A download has been initiated. " +
                "Wait for the model to download, then restart the meeting capture. " +
                "Monitor progress in Settings → General → Language & Region → Speech Recognition."
            )
        }

        // Genuinely installed. Reserve it (or confirm it's already reserved)
        // so it keeps reporting available — reserve-and-proceed, never a
        // re-download or a toast for an installed-but-not-reserved locale.
        await Permission.ensureLocaleReserved(locale, logPrefix: "[ChannelTranscriber]")
    }

    // MARK: - Prepare

    /// Prepare the SpeechAnalyzer with the optimal audio format.
    /// Must be called before any call to `ingest(_:)` or `start()`.
    func prepare() async throws {
        do {
            // Ask the analyzer for the best format compatible with this transcriber.
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: nil
            )
            analyzerFormat = format  // nil = let the analyzer pick its own default
            try await analyzer.prepareToAnalyze(in: format)
            Log.info("[ChannelTranscriber:\(speaker)] prepared with format: \(format?.description ?? "default")")
        } catch {
            throw TranscriptionEngineError.analyzerPreparationFailed(underlying: error)
        }
    }

    // MARK: - Start

    /// Start the analysis loop and result consumer. Call after `prepare()`.
    func start() {
        // Analysis task: feeds the AsyncStream into the SpeechAnalyzer.
        // analyzeSequence runs until continuation.finish() is called in stop().
        let analyzerRef = analyzer
        let streamRef = stream
        let speakerLabel = speaker
        analysisTask = Task(priority: .userInitiated) {
            Log.info("[ChannelTranscriber:\(speakerLabel)] analyzeSequence starting")
            do {
                let _ = try await analyzerRef.analyzeSequence(streamRef)
                Log.info("[ChannelTranscriber:\(speakerLabel)] analyzeSequence completed normally")
            } catch {
                Log.info("[ChannelTranscriber:\(speakerLabel)] analyzeSequence error: \(error.localizedDescription)")
            }
            Log.info("[ChannelTranscriber:\(speakerLabel)] analyzeSequence task exiting")
        }

        // Result task: consume finalized transcriptions and append to conversation.jsonl.
        let transcriberRef = transcriber
        let logRef = log
        resultTask = Task(priority: .userInitiated) {
            do {
                for try await result in transcriberRef.results {
                    // Skip volatile (in-progress) results; only append finalized ones.
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                    let (audioStart, audioEnd) = Self.audioRange(of: result.text)

                    // Live diarization tagging — "Them" only (the merged
                    // remote-participant channel; "You" is already
                    // unambiguous). Only queryable when both endpoints of
                    // this line's audio interval are known; if the diarizer
                    // hasn't produced a segment covering this interval yet
                    // (its rolling window lags live audio by up to ~10s),
                    // this simply returns empty and the line writes with no
                    // label — patchable later via rewriteSpeakerLabel.
                    var liveSpeakerLabel: String?
                    if #available(macOS 26.0, *), speakerLabel == "Them",
                       let start = audioStart, let end = audioEnd {
                        let voiceIds = await SpeakerDiarizationService.shared.voiceIds(overlapping: start, end: end)
                        liveSpeakerLabel = voiceIds.first
                    }

                    await logRef.append(
                        speaker: speakerLabel,
                        text: text,
                        audioStartSeconds: audioStart,
                        audioEndSeconds: audioEnd,
                        speakerLabel: liveSpeakerLabel
                    )
                }
            } catch {
                Log.info("[ChannelTranscriber:\(speakerLabel)] results iteration ended: \(error.localizedDescription)")
            }
            Log.info("[ChannelTranscriber:\(speakerLabel)] result task complete")
        }

        Log.info("[ChannelTranscriber:\(speaker)] started")
    }

    // MARK: - Audio time range extraction

    /// Compute the overall spoken-audio interval (seconds) covered by a
    /// finalized result's text, from the per-run `audioTimeRange` attribute
    /// (present because `attributeOptions` includes `.audioTimeRange`, see
    /// `init`). A finalized result's text can carry multiple runs — each
    /// word/segment may have its own `audioTimeRange` — so this takes the
    /// earliest start and latest end across all runs that report one.
    ///
    /// Returns (nil, nil) when no run in this result carries the attribute.
    /// This is a known, occasionally-observed gap in SpeechTranscriber's
    /// reporting (not just a "You" vs "Them" channel distinction) — callers
    /// must tolerate it rather than treat it as an error.
    static func audioRange(of text: AttributedString) -> (start: Double?, end: Double?) {
        var earliestStart: Double?
        var latestEnd: Double?
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            if earliestStart == nil || start < earliestStart! { earliestStart = start }
            if latestEnd == nil || end > latestEnd! { latestEnd = end }
        }
        return (earliestStart, latestEnd)
    }

    // MARK: - Buffer ingestion

    // Diagnostic ingest counter — counts every buffer delivered to this transcriber.
    // nonisolated(unsafe): written/read on the SCStream queue only; no cross-thread writes.
    private nonisolated(unsafe) var _ingestCount: Int = 0

    // Conversion-error counter for rate-limiting log output.
    // nonisolated(unsafe): written/read on the SCStream queue only.
    private nonisolated(unsafe) var _convertErrorCount: Int = 0

    /// Ingest a CMSampleBuffer from the SCStream queue.
    /// Converts CMSampleBuffer → AVAudioPCMBuffer → AnalyzerInput and pushes
    /// into the AsyncStream continuation. nonisolated: called on SCStream's queue.
    nonisolated func ingest(_ sampleBuffer: CMSampleBuffer) {
        _ingestCount += 1
        let n = _ingestCount
        // Log first buffer (proves audio is arriving) and every 200 thereafter.
        if n == 1 || n % 200 == 0 {
            Log.info("[ChannelTranscriber:\(speaker)] ingest() buffer #\(n)")
        }
        guard let pcmBuffer = convertToPCM(sampleBuffer) else {
            if n == 1 {
                Log.info("[ChannelTranscriber:\(speaker)] ingest() buffer #\(n): convertToPCM returned nil — check format")
            }
            return
        }
        // Do NOT pass bufferStartTime. Feeding the live SCStream PTS makes
        // SpeechAnalyzer reject inputs with "Audio input timestamp overlaps or
        // precedes prior audio input": once the buffer is resampled to the
        // analyzer's format, its frame-count duration no longer matches the
        // source PTS deltas, so consecutive intervals overlap. Omitting the
        // anchor makes the analyzer treat the input as a contiguous stream and
        // sequence by frame count — the supported live-transcription pattern.
        let input = AnalyzerInput(buffer: pcmBuffer)
        continuation?.yield(input)
    }

    /// Ingest a pre-decoded AVAudioPCMBuffer directly (fixture/test path).
    ///
    /// Used by FixtureWAVFeeder to feed canned audio into the transcription
    /// pipeline without going through a live SCStream. The buffer is transcoded
    /// to the analyzer's preferred format if needed (same lazy-converter path
    /// as ingest(_:)). Called from any queue; safe because continuation and
    /// analyzerFormat are written-once before any ingest call.
    ///
    /// - Parameters:
    ///   - pcmBuffer: Pre-decoded audio buffer in any format.
    ///   - presentationTime: Optional timeline anchor (CMTime.invalid = no anchor).
    nonisolated func ingestPCM(_ pcmBuffer: AVAudioPCMBuffer, at presentationTime: CMTime = .invalid) {
        guard let converted = convertPCMToAnalyzerFormat(pcmBuffer) else { return }
        // Omit bufferStartTime (same reason as ingest(_:)): the analyzer
        // sequences contiguous buffers by frame count; an explicit anchor that
        // doesn't match the resampled frame duration trips the "timestamp
        // overlaps or precedes" error and kills the results stream.
        _ = presentationTime  // anchor intentionally unused; kept for API compat
        let input = AnalyzerInput(buffer: converted)
        continuation?.yield(input)
    }

    // MARK: - Stop

    /// Stop the transcriber: finalize the stream and wait for tasks to complete.
    ///
    /// ## Ordering contract (crash fix)
    ///
    /// `finalizeAndFinishThroughEndOfInput()` must be called AFTER `analyzeSequence`
    /// has fully drained, not before. Calling it while `analyzeSequence` is still
    /// consuming queued elements transitions the SpeechAnalyzer to its "finalizing"
    /// internal state while the analysis loop is still mid-segment. On the next call
    /// to `SpeechAnalyzer.processInput`, the framework invokes
    /// `SpeechRecognizerWorker.preRunRecognition` to begin a new recognition run —
    /// but the analyzer is now in "finalizing" state, violating the framework's
    /// internal invariant → EXC_BREAKPOINT at the same fixed PC every time.
    ///
    /// Correct order:
    ///   1. End the AsyncStream (continuation.finish) — no more audio can be queued.
    ///   2. Await analysisTask — analyzeSequence drains all buffered elements and returns.
    ///   3. Call finalizeAndFinishThroughEndOfInput — safe now; analyzer is idle.
    ///   4. Await resultTask — consumes final transcription results from transcriber.results.
    func stop() async {
        Log.info("[ChannelTranscriber:\(speaker)] stop() — finishing stream (ingest count=\(_ingestCount))")

        // Step 1: Signal end-of-input. No more buffers will be queued after this.
        continuation?.finish()
        continuation = nil

        // Step 2: CRITICAL — drain analyzeSequence BEFORE calling finalizeAndFinishThroughEndOfInput.
        // analyzeSequence() is still running in analysisTask and may still be processing
        // queued AnalyzerInput elements. Calling finalizeAndFinishThroughEndOfInput() now
        // would race with analyzeSequence's internal processInput → preRunRecognition call,
        // causing an EXC_BREAKPOINT (SpeechRecognizerWorker.preRunRecognition assertion).
        Log.info("[ChannelTranscriber:\(speaker)] stop() — awaiting analysisTask drain")
        await analysisTask?.value
        analysisTask = nil
        Log.info("[ChannelTranscriber:\(speaker)] stop() — analysisTask drained")

        // Step 3: Finalize the analyzer. Called only after analyzeSequence has returned,
        // so the analyzer is idle — no concurrent processInput calls possible.
        // This flushes any remaining audio buffered inside the analyzer and emits
        // the final transcription results to transcriber.results.
        do {
            Log.info("[ChannelTranscriber:\(speaker)] stop() — calling finalizeAndFinishThroughEndOfInput")
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            Log.info("[ChannelTranscriber:\(speaker)] stop() — finalize succeeded")
        } catch {
            Log.info("[ChannelTranscriber:\(speaker)] stop() — finalize error (\(error.localizedDescription)), cancelling")
            await analyzer.cancelAndFinishNow()
        }

        // Step 4: Drain the result task — consumes final SpeechTranscriptionResults
        // from transcriber.results and appends them to conversation.jsonl.
        Log.info("[ChannelTranscriber:\(speaker)] stop() — awaiting resultTask drain")
        await resultTask?.value
        resultTask = nil

        Log.info("[ChannelTranscriber:\(speaker)] stopped and finalized (ingest total=\(_ingestCount))")
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer conversion

    /// Convert a CMSampleBuffer (from SCStream LPCM delivery) to AVAudioPCMBuffer.
    ///
    /// SCStream delivers LPCM audio at 16 kHz mono. We copy the PCM data into an
    /// AVAudioPCMBuffer, then optionally transcode to the analyzer's preferred format
    /// via a lazily-created AVAudioConverter.
    ///
    /// nonisolated: called on the SCStream queue. Accesses nonisolated(unsafe) fields
    /// that are written-once before this method can be invoked (prepare() completes
    /// before start() subscribes the ingest closure).
    nonisolated private func convertToPCM(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Get the audio format from the sample buffer.
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // Allocate an AVAudioPCMBuffer in the source format.
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return nil
        }
        srcBuffer.frameLength = frameCount

        // Copy PCM data from CMSampleBuffer into the AVAudioPCMBuffer's AudioBufferList.
        // We use the mutableAudioBufferList pointer that AVAudioPCMBuffer owns.
        let ablPtr = srcBuffer.mutableAudioBufferList
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: ablPtr
        )
        guard status == noErr else {
            Log.info("[ChannelTranscriber:\(speaker)] CMSampleBufferCopyPCMDataIntoAudioBufferList failed: \(status)")
            return nil
        }

        // If analyzer format not set yet (pre-prepare), or formats already match, return directly.
        guard let targetFormat = analyzerFormat, srcFormat != targetFormat else {
            return srcBuffer
        }

        // Self-healing converter: rebuild whenever the incoming buffer's actual format
        // no longer matches what the cached converter was built for.
        //
        // Why this matters for mic hot-swap: after resetMicTranscriber() creates a fresh
        // ChannelTranscriber, the first buffers it ingests may still arrive from the OLD
        // device (SCStream hasn't flipped to the new device yet). If we only check for
        // nil, those stale-device buffers permanently bake a wrong channelMap into the
        // converter — every subsequent buffer from the real new device fails (OSStatus -1),
        // and transcription is silently dead for the rest of the session.
        //
        // By also checking converter?.inputFormat != srcFormat, we detect the format
        // change on the very first buffer that arrives in the new device's format and
        // rebuild the converter (with a correct channelMap) before any audio is lost.
        // This is safe for an arbitrary number of hot-swaps in one session.
        //
        // nonisolated(unsafe) is safe here because prepare() always runs before ingest().
        let needsRebuild = converter.map { $0.inputFormat != srcFormat } ?? true
        if needsRebuild {
            if let existingConv = converter {
                // Converter exists but its input format no longer matches — format changed
                // (e.g. mic hot-swap: old device 2ch, new device 1ch, or vice versa).
                Log.info("[ChannelTranscriber:\(speaker)] convertToPCM: input format changed " +
                    "(\(existingConv.inputFormat.channelCount)ch → \(srcFormat.channelCount)ch, " +
                    "sr \(existingConv.inputFormat.sampleRate) → \(srcFormat.sampleRate)) — rebuilding converter")
                converter = nil
            }
            let newConv = AVAudioConverter(from: srcFormat, to: targetFormat)
            // For channel-count mismatches (e.g. stereo USB mic → mono analyzer),
            // AVAudioConverter requires an explicit channelMap to perform the downmix.
            // Without one it returns OSStatus -1 on every convert() call.
            // Strategy: map output channel i ← input channel i, clamped to available
            // input channels (so a mono analyzer always picks the first mic channel).
            if let conv = newConv, srcFormat.channelCount != targetFormat.channelCount {
                let outputCount = Int(targetFormat.channelCount)
                let inputCount  = Int(srcFormat.channelCount)
                conv.channelMap = (0..<outputCount).map { i in
                    NSNumber(value: min(i, inputCount - 1))
                }
                Log.info("[ChannelTranscriber:\(speaker)] configured channelMap for \(srcFormat.channelCount)ch→\(targetFormat.channelCount)ch downmix")
            }
            converter = newConv
        }
        // CRASH FIX: converter init can return nil for unsupported format combos.
        // Drop the buffer — never feed the wrong-format srcBuffer to SpeechAnalyzer.
        guard let conv = converter else { return nil }

        // Calculate output capacity accounting for sample rate ratio.
        let ratio = targetFormat.sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        // CRASH FIX: drop on dstBuffer alloc failure; never fall back to srcBuffer.
        guard let dstBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outCapacity
        ) else { return nil }

        // Perform the conversion. The input callback provides srcBuffer once.
        // Using a class-based flag so the @Sendable capture is over a reference type.
        final class InputFlag: @unchecked Sendable { var provided = false }
        var convError: NSError?
        let flag = InputFlag()
        let inputBuf = srcBuffer
        conv.convert(to: dstBuffer, error: &convError) { _, outStatus in
            guard !flag.provided else {
                outStatus.pointee = .noDataNow
                return nil
            }
            flag.provided = true
            outStatus.pointee = .haveData
            return inputBuf
        }

        if let e = convError {
            // CRASH FIX: on conversion failure, drop the buffer.
            // Returning srcBuffer here was the original crash: feeding a wrong-channel-count
            // buffer to SpeechAnalyzer triggered EXC_BREAKPOINT in preRunRecognition.
            _convertErrorCount += 1
            if _convertErrorCount == 1 || _convertErrorCount % 200 == 0 {
                Log.info("[ChannelTranscriber:\(speaker)] AVAudioConverter error #\(_convertErrorCount): \(e.localizedDescription)")
            }
            return nil
        }

        // CRASH FIX: drop if the converter produced nothing; never fall back to srcBuffer.
        return dstBuffer.frameLength > 0 ? dstBuffer : nil
    }

    /// Convert an existing AVAudioPCMBuffer to the analyzer's preferred format.
    ///
    /// Used by ingestPCM(_:at:) (fixture/test path) to apply the same lazy-
    /// converter transcoding logic as convertToPCM(_:) without going through
    /// CMSampleBuffer. Returns the input buffer unchanged if formats match or
    /// if no analyzer format has been set yet.
    ///
    /// nonisolated: same thread-safety contract as convertToPCM.
    nonisolated private func convertPCMToAnalyzerFormat(_ srcBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let srcFormat   = srcBuffer.format
        let frameCount  = srcBuffer.frameLength
        guard frameCount > 0 else { return nil }

        // If analyzer format not set yet, or formats already match, return directly.
        guard let targetFormat = analyzerFormat, srcFormat != targetFormat else {
            return srcBuffer
        }

        // Self-healing converter: same rebuild-on-format-change logic as convertToPCM.
        // Rebuilds whenever the incoming buffer's format differs from the cached converter's
        // input format (covers hot-swap transitions in the fixture/test path).
        let needsRebuild = converter.map { $0.inputFormat != srcFormat } ?? true
        if needsRebuild {
            if let existingConv = converter {
                Log.info("[ChannelTranscriber:\(speaker)] convertPCMToAnalyzerFormat: input format changed " +
                    "(\(existingConv.inputFormat.channelCount)ch → \(srcFormat.channelCount)ch) — rebuilding converter")
                converter = nil
            }
            let newConv = AVAudioConverter(from: srcFormat, to: targetFormat)
            // Same channelMap fix as convertToPCM: configure downmix for mismatched channel counts.
            if let conv = newConv, srcFormat.channelCount != targetFormat.channelCount {
                let outputCount = Int(targetFormat.channelCount)
                let inputCount  = Int(srcFormat.channelCount)
                conv.channelMap = (0..<outputCount).map { i in
                    NSNumber(value: min(i, inputCount - 1))
                }
                Log.info("[ChannelTranscriber:\(speaker)] convertPCMToAnalyzerFormat: channelMap set \(srcFormat.channelCount)ch→\(targetFormat.channelCount)ch")
            }
            converter = newConv
        }
        // CRASH FIX: drop on nil converter; never fall back to srcBuffer.
        guard let conv = converter else { return nil }

        let ratio      = targetFormat.sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        // CRASH FIX: drop on alloc failure; never fall back to srcBuffer.
        guard let dstBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outCapacity
        ) else { return nil }

        final class InputFlag: @unchecked Sendable { var provided = false }
        var convError: NSError?
        let flag     = InputFlag()
        let inputBuf = srcBuffer
        conv.convert(to: dstBuffer, error: &convError) { _, outStatus in
            guard !flag.provided else { outStatus.pointee = .noDataNow; return nil }
            flag.provided            = true
            outStatus.pointee        = .haveData
            return inputBuf
        }

        if let e = convError {
            // CRASH FIX: drop on error; never return the wrong-format srcBuffer.
            _convertErrorCount += 1
            if _convertErrorCount == 1 || _convertErrorCount % 200 == 0 {
                Log.info("[ChannelTranscriber:\(speaker)] convertPCMToAnalyzerFormat error #\(_convertErrorCount): \(e.localizedDescription)")
            }
            return nil
        }
        // CRASH FIX: drop empty dst; never fall back to srcBuffer.
        return dstBuffer.frameLength > 0 ? dstBuffer : nil
    }
}

// MARK: - TranscriberHolder

/// Thread-safe storage for the active ChannelTranscriber instances.
/// Written on @MainActor (start/stop); read on the SCStream queue (nonisolated).
///
/// Stores as AnyObject so the holder itself has no macOS 26+ availability requirement.
/// The @available(macOS 26.0, *) typed accessors cast back to ChannelTranscriber.
/// All accesses use NSLock for correct cross-queue safety.
///
/// `_mic`/`_system` use nonisolated(unsafe) because the default @MainActor isolation
/// would prevent read from the SCStream queue; NSLock makes them safe.
final class TranscriberHolder: @unchecked Sendable {
    private let lock = NSLock()
    // Stored as AnyObject? so the holder type itself requires no @available annotation.
    private nonisolated(unsafe) var _mic: AnyObject?
    private nonisolated(unsafe) var _system: AnyObject?

    @available(macOS 26.0, *)
    nonisolated var micTranscriber: ChannelTranscriber? {
        lock.withLock { _mic as? ChannelTranscriber }
    }

    @available(macOS 26.0, *)
    nonisolated var systemTranscriber: ChannelTranscriber? {
        lock.withLock { _system as? ChannelTranscriber }
    }

    @available(macOS 26.0, *)
    func set(mic: ChannelTranscriber, system: ChannelTranscriber) {
        lock.withLock { _mic = mic; _system = system }
    }

    @available(macOS 26.0, *)
    func take() -> (ChannelTranscriber?, ChannelTranscriber?) {
        lock.withLock {
            let m = _mic as? ChannelTranscriber
            let s = _system as? ChannelTranscriber
            _mic = nil; _system = nil
            return (m, s)
        }
    }

    /// Clear only the mic slot and return the displaced transcriber.
    /// Used by mic-device hot-swap: drains the old session before the new device starts.
    @available(macOS 26.0, *)
    func takeMic() -> ChannelTranscriber? {
        lock.withLock {
            let m = _mic as? ChannelTranscriber
            _mic = nil
            return m
        }
    }

    /// Set only the mic slot (system slot unchanged).
    /// Used by mic-device hot-swap: wires in the fresh ChannelTranscriber after prepare().
    @available(macOS 26.0, *)
    func setMic(_ mic: ChannelTranscriber) {
        lock.withLock { _mic = mic }
    }
}

// MARK: - FixtureWAVFeeder

/// Reads a canned WAV file (or two mono files) and feeds decoded audio buffers
/// directly into two ChannelTranscribers, bypassing the live SCStream entirely.
///
/// This is the implementation of the WORK42_MEETING_FIXTURE_WAV env-var seam
/// (AC21). It is ONLY instantiated when the env var is set; otherwise the seam
/// is completely inert.
///
/// ## Channel routing
///
///   Stereo WAV (single path):
///     Left  channel → mic/You  ChannelTranscriber
///     Right channel → system/Them ChannelTranscriber
///
///   Two mono WAVs (colon-separated path):
///     First  file → mic/You  ChannelTranscriber
///     Second file → system/Them ChannelTranscriber
///
/// ## Streaming cadence
///
/// Buffers are fed in chunks of CHUNK_FRAMES frames with a proportional sleep
/// between each chunk so the SpeechAnalyzer receives realistic streaming audio
/// rather than one enormous buffer (which can cause timeout or stall).
///
/// ## Concurrency
///
/// `feed(micT:systemT:)` is an async function meant to be run in a detached
/// Task. It is `nonisolated` (no actor isolation) and calls `ingestPCM(_:at:)`
/// on the transcribers (which is also nonisolated).
@available(macOS 26.0, *)
final class FixtureWAVFeeder: @unchecked Sendable {

    // MARK: - Constants

    /// Number of frames per chunk fed to each ChannelTranscriber.
    /// 16 kHz × 0.1 s = 1 600 frames per chunk — matches typical SCStream cadence.
    private static let CHUNK_FRAMES: AVAudioFrameCount = 1_600

    // MARK: - Stored paths

    /// URL for the mic/You channel (mono, or left of stereo).
    let micURL: URL
    /// URL for the system/Them channel (mono), or nil when using a stereo file.
    let systemURL: URL?
    /// True when a single stereo file is used (systemURL is nil).
    let isStereo: Bool

    // MARK: - Init

    /// Initialise from the env-var string (single path or "path1:path2").
    ///
    /// Returns nil if the env-var value is empty or the paths don't exist.
    init?(envValue: String) {
        let parts = envValue.split(separator: ":", maxSplits: 1).map { String($0) }
        switch parts.count {
        case 1:
            let url = URL(fileURLWithPath: parts[0])
            guard FileManager.default.fileExists(atPath: url.path) else {
                Log.info("[FixtureWAVFeeder] WAV not found at \(url.path)")
                return nil
            }
            self.micURL    = url
            self.systemURL = nil
            self.isStereo  = true
        case 2:
            let u1 = URL(fileURLWithPath: parts[0])
            let u2 = URL(fileURLWithPath: parts[1])
            guard FileManager.default.fileExists(atPath: u1.path),
                  FileManager.default.fileExists(atPath: u2.path) else {
                Log.info("[FixtureWAVFeeder] one or both mono WAV files not found: \(parts)")
                return nil
            }
            self.micURL    = u1
            self.systemURL = u2
            self.isStereo  = false
        default:
            Log.info("[FixtureWAVFeeder] invalid env-var format (expected one path or 'path1:path2')")
            return nil
        }
    }

    // MARK: - Feed

    /// Read the fixture WAV(s), split channels, and stream buffers into the two transcriberss.
    ///
    /// - Parameters:
    ///   - micT:    ChannelTranscriber for "You" (already prepared and started).
    ///   - systemT: ChannelTranscriber for "Them" (already prepared and started).
    ///
    /// Returns when all audio has been ingested. Call `stop()` on both transcriberss
    /// afterward (MeetingTranscriptionEngine.stop() does this).
    func feed(micT: ChannelTranscriber, systemT: ChannelTranscriber) async {
        do {
            if isStereo {
                try await feedStereo(micURL: micURL, micT: micT, systemT: systemT)
            } else {
                // Feed both mono files concurrently so You+Them are interleaved in time.
                let systemPath = systemURL!  // safe: isStereo=false guarantees non-nil
                async let micDone:    Void = feedMono(url: micURL,    transcriber: micT)
                async let systemDone: Void = feedMono(url: systemPath, transcriber: systemT)
                _ = try await (micDone, systemDone)
            }
        } catch {
            Log.info("[FixtureWAVFeeder] feed error: \(error.localizedDescription)")
        }
        Log.info("[FixtureWAVFeeder] fixture feed complete")
    }

    // MARK: - Stereo path

    /// Read a stereo WAV, extract left and right channel mono buffers chunk-by-chunk,
    /// and feed them to the two transcriberss simultaneously.
    private func feedStereo(
        micURL: URL,
        micT: ChannelTranscriber,
        systemT: ChannelTranscriber
    ) async throws {
        let file = try AVAudioFile(forReading: micURL)
        let srcFormat = file.processingFormat

        guard srcFormat.channelCount >= 2 else {
            // Stereo file has only one channel — treat as mic-only.
            Log.info("[FixtureWAVFeeder] stereo WAV has \(srcFormat.channelCount) channel(s); routing all to You")
            try await feedMono(url: micURL, transcriber: micT)
            return
        }

        // Read the entire file into one buffer, then split channels.
        // For long fixtures we chunk the read to avoid large allocations.
        let chunkFrames = Self.CHUNK_FRAMES
        let totalFrames = AVAudioFrameCount(file.length)
        var offset: AVAudioFramePosition = 0

        // Build a mono AVAudioFormat matching the source (same sample rate, 1 ch).
        guard let monoFormat = AVAudioFormat(
            commonFormat: srcFormat.commonFormat,
            sampleRate:   srcFormat.sampleRate,
            channels:     1,
            interleaved:  false
        ) else {
            Log.info("[FixtureWAVFeeder] could not build mono format from stereo source")
            return
        }

        while offset < totalFrames {
            let framesThisChunk = min(chunkFrames, AVAudioFrameCount(totalFrames - AVAudioFrameCount(offset)))

            guard let chunk = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: framesThisChunk) else {
                break
            }
            do {
                try file.read(into: chunk, frameCount: framesThisChunk)
            } catch {
                Log.info("[FixtureWAVFeeder] stereo read error at frame \(offset): \(error.localizedDescription)")
                break
            }
            guard chunk.frameLength > 0 else { break }

            // Extract left (channel 0) → You and right (channel 1) → Them.
            // Non-interleaved float32 layout: floatChannelData![channelIdx][frame].
            if srcFormat.commonFormat == .pcmFormatFloat32,
               let channelData = chunk.floatChannelData,
               let micBuf  = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk.frameLength),
               let themBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk.frameLength) {

                micBuf.frameLength  = chunk.frameLength
                themBuf.frameLength = chunk.frameLength

                // Copy left channel → mic buffer.
                memcpy(micBuf.floatChannelData![0],
                       channelData[0],
                       Int(chunk.frameLength) * MemoryLayout<Float>.size)

                // Copy right channel → them buffer.
                memcpy(themBuf.floatChannelData![0],
                       channelData[1],
                       Int(chunk.frameLength) * MemoryLayout<Float>.size)

                let ts = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(srcFormat.sampleRate))
                micT.ingestPCM(micBuf, at: ts)
                systemT.ingestPCM(themBuf, at: ts)

            } else if srcFormat.commonFormat == .pcmFormatInt16,
                      let channelData = chunk.int16ChannelData,
                      let micBuf  = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk.frameLength),
                      let themBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk.frameLength) {

                micBuf.frameLength  = chunk.frameLength
                themBuf.frameLength = chunk.frameLength

                memcpy(micBuf.int16ChannelData![0],
                       channelData[0],
                       Int(chunk.frameLength) * MemoryLayout<Int16>.size)
                memcpy(themBuf.int16ChannelData![0],
                       channelData[1],
                       Int(chunk.frameLength) * MemoryLayout<Int16>.size)

                let ts = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(srcFormat.sampleRate))
                micT.ingestPCM(micBuf, at: ts)
                systemT.ingestPCM(themBuf, at: ts)

            } else {
                // Unsupported format: route entire chunk to both channels as-is.
                // SpeechAnalyzer will transcode via the lazy converter.
                let ts = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(srcFormat.sampleRate))
                micT.ingestPCM(chunk, at: ts)
                systemT.ingestPCM(chunk, at: ts)
            }

            offset += AVAudioFramePosition(chunk.frameLength)

            // Throttle: sleep proportional to the chunk duration so we don't
            // flood the SpeechAnalyzer faster than real-time.
            let chunkDurationNs = UInt64(Double(chunk.frameLength) / srcFormat.sampleRate * 1_000_000_000)
            try? await Task.sleep(nanoseconds: chunkDurationNs)
        }
    }

    // MARK: - Mono path

    /// Read a mono WAV (or any single-channel audio file) and feed it chunk-by-chunk
    /// to one ChannelTranscriber.
    private func feedMono(url: URL, transcriber: ChannelTranscriber) async throws {
        let file = try AVAudioFile(forReading: url)
        let srcFormat   = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        let chunkFrames = Self.CHUNK_FRAMES
        var offset: AVAudioFramePosition = 0

        while offset < totalFrames {
            let framesThisChunk = min(chunkFrames, AVAudioFrameCount(totalFrames - AVAudioFrameCount(offset)))
            guard let chunk = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: framesThisChunk) else {
                break
            }
            do {
                try file.read(into: chunk, frameCount: framesThisChunk)
            } catch {
                Log.info("[FixtureWAVFeeder] mono read error at frame \(offset): \(error.localizedDescription)")
                break
            }
            guard chunk.frameLength > 0 else { break }

            let ts = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(srcFormat.sampleRate))
            transcriber.ingestPCM(chunk, at: ts)

            offset += AVAudioFramePosition(chunk.frameLength)

            let chunkDurationNs = UInt64(Double(chunk.frameLength) / srcFormat.sampleRate * 1_000_000_000)
            try? await Task.sleep(nanoseconds: chunkDurationNs)
        }
    }
}

// MARK: - MeetingTranscriptionEngine

/// @MainActor singleton that wires two SpeechTranscriber sessions into
/// MeetingTranscriptionService for live conversation.jsonl output.
///
/// ## Lifecycle
///
/// 1. `setup()` — call once at app startup to wire seam closures into
///    `MeetingTranscriptionService`. The closures are long-lived (survive
///    start/stop cycles) and route buffers via TranscriberHolder.
/// 2. `start(sessionDir:)` — called by MeetingTranscriptionService.start().
///    Creates two ChannelTranscribers, prepares them, and starts analysis.
///    Fails loud (throws) if the speech model is not available.
/// 3. `stop()` — called by MeetingTranscriptionService.stop().
///    Finalizes both transcriberss and the conversation log.
///
/// ## fail-loud contract
///
/// If the macOS 26 speech model is not available or not installed,
/// `start()` throws `TranscriptionEngineError.speechModelUnavailable`
/// and the meeting capture is aborted. The user sees a named error.
/// There is no silent degradation to zero-lines output.
@MainActor
@Observable
final class MeetingTranscriptionEngine {

    // MARK: - Singleton

    static let shared = MeetingTranscriptionEngine()
    private init() {}

    // MARK: - Observable state

    /// True while transcription is active.
    private(set) var isTranscribing: Bool = false

    /// Last fail-loud transcription error. Non-nil when start() threw.
    private(set) var lastError: (any Error)?

    // MARK: - Internals

    private let holder = TranscriberHolder()
    private var conversationLog: ConversationLog?

    /// RecordingCore subscription tokens for the live mic / system-audio taps
    /// wired in `setup()`. Removed and re-added if `setup()` runs again.
    private var micBufferToken: SubscriptionToken?
    private var systemBufferToken: SubscriptionToken?

    // MARK: - Fixture-mode state (AC21)

    /// Active fixture feed task. Non-nil only in fixture mode while feeding.
    /// Cancelled (and awaited) in stop() so finalization is correct.
    private var fixtureTask: Task<Void, Never>?

    /// True when the engine was started in fixture mode.
    private(set) var isFixtureMode: Bool = false

    // MARK: - Setup (call once at app startup)

    /// Wire the transcription seam into MeetingTranscriptionService.
    ///
    /// Sets the long-lived `onMicBuffer` / `onSystemAudioBuffer` closures.
    /// Must be called BEFORE any `MeetingTranscriptionService.start()` call.
    ///
    /// This is a no-op in fixture mode: the fixture feeds buffers directly via
    /// ingestPCM(_:at:), bypassing the SCStream handler closures entirely.
    func setup() {
        let holderRef = holder
        // Route live RecordingCore audio directly into the per-channel
        // transcribers. In work42 this was bridged through
        // MeetingTranscriptionService's onMicBuffer/onSystemAudioBuffer
        // closures; that orchestration layer is replaced by meet42 CLI verbs,
        // so the engine subscribes to RecordingCore itself. Previously-set
        // handlers are removed first so repeated setup() calls don't stack.
        if let t = micBufferToken { RecordingCore.shared.removeHandler(t); micBufferToken = nil }
        if let t = systemBufferToken { RecordingCore.shared.removeHandler(t); systemBufferToken = nil }
        micBufferToken = RecordingCore.shared.addMicHandler { buf in
            if #available(macOS 26.0, *) {
                holderRef.micTranscriber?.ingest(buf)
            }
        }
        systemBufferToken = RecordingCore.shared.addSystemAudioHandler { buf in
            if #available(macOS 26.0, *) {
                holderRef.systemTranscriber?.ingest(buf)
            }
        }

        // Register the mic-device-will-change hook so RecordingCore.applySelectedMicrophoneDevice()
        // can coordinate a SpeechAnalyzer session reset with the SCStream device swap.
        //
        // Without this, feeding audio from a different hardware mic source to the same
        // long-lived SpeechAnalyzer crashes inside Apple's private Speech framework
        // (EXC_BREAKPOINT in SpeechRecognizerWorker.preRunRecognition, Thread 8).
        //
        // The hook fires on @MainActor, before the SCStream is reconfigured, giving us
        // a safe async window to finalize the old "You" ChannelTranscriber and prepare
        // a fresh one. The "Them" channel is unaffected throughout.
        if #available(macOS 26.0, *) {
            RecordingCore.shared.onMicDeviceWillChange = { [weak self] in
                guard let self else { return }
                await self.resetMicTranscriber()
            }
        }

        Log.info("[MeetingTranscriptionEngine] audio taps wired into RecordingCore")
    }

    // MARK: - Mic hot-swap session reset

    /// Finalize the mic ("You") ChannelTranscriber for the old device and start a fresh
    /// one, in coordination with RecordingCore's live mic hot-swap.
    ///
    /// Called by `RecordingCore.onMicDeviceWillChange` just before the SCStream's mic
    /// device is changed. The sequence is:
    ///
    ///   1. Remove the old mic transcriber from the holder so no further ingest() calls
    ///      reach the old SpeechAnalyzer.
    ///   2. Await finalization of the old SpeechAnalyzer session (flush buffered audio,
    ///      emit final transcription lines). This is a clean end-of-stream signal — the
    ///      analyzer is NOT killed abruptly.
    ///   3. Create, prepare, and start a fresh ChannelTranscriber whose SpeechAnalyzer
    ///      begins a new, anchored audio timeline for the new device.
    ///   4. Wire the fresh transcriber into the holder so ingest() calls from the new
    ///      device's buffers land on the clean session.
    ///
    /// The "Them" channel is completely unaffected — its SpeechAnalyzer continues without
    /// interruption through the swap.
    ///
    /// Coverage gap: mic buffers are dropped during steps 2–3 (old finalization +
    /// new prepare, typically < 1 s). This is an acceptable trade-off for crash safety:
    /// the alternative is EXC_BREAKPOINT inside Apple's private Speech framework.
    ///
    /// Not called in fixture mode (FixtureWAVFeeder bypasses RecordingCore entirely).
    @available(macOS 26.0, *)
    private func resetMicTranscriber() async {
        Log.info("[MeetingTranscriptionEngine] mic hot-swap: resetMicTranscriber() entry — isTranscribing=\(isTranscribing) hasLog=\(conversationLog != nil)")
        guard isTranscribing, let log = conversationLog else {
            Log.info("[MeetingTranscriptionEngine] mic hot-swap: not transcribing or no log — skipping ChannelTranscriber reset")
            return
        }

        // Step 1: Atomically take the old mic transcriber out of the holder.
        // From this point forward, ingest() calls on the SCStream queue no longer reach
        // the old SpeechAnalyzer. Buffers during finalization are silently dropped.
        let oldMic = holder.takeMic()
        Log.info("[MeetingTranscriptionEngine] mic hot-swap: step1 takeMic complete — oldMic=\(oldMic != nil ? "present" : "nil (no previous transcriber)")")

        if let old = oldMic {
            Log.info("[MeetingTranscriptionEngine] mic hot-swap: step2 begin — stopping old 'You' ChannelTranscriber")
            // Step 2: Finalize cleanly — flushes remaining buffered audio and emits the
            // last transcription lines to conversation.jsonl before tearing down.
            // stop() now awaits analyzeSequence BEFORE calling finalizeAndFinishThroughEndOfInput
            // so there is no concurrent preRunRecognition call during finalization.
            await old.stop()
            Log.info("[MeetingTranscriptionEngine] mic hot-swap: step2 complete — old 'You' ChannelTranscriber stopped")
        }

        // Step 3: Create a fresh ChannelTranscriber.
        // A new SpeechAnalyzer begins a new, gapless session — anchored to the new
        // device's audio timeline from its first buffer.
        Log.info("[MeetingTranscriptionEngine] mic hot-swap: step3 — creating fresh 'You' ChannelTranscriber")
        let newMic = ChannelTranscriber(speaker: "You", log: log)
        do {
            Log.info("[MeetingTranscriptionEngine] mic hot-swap: step3 — calling prepare()")
            try await newMic.prepare()
            Log.info("[MeetingTranscriptionEngine] mic hot-swap: step3 — prepare() succeeded")
        } catch {
            // Preparation failed (model issue). Leave the holder's mic slot empty.
            // The meeting continues (Them channel is unaffected); mic transcription is
            // paused until the next hot-swap or a meeting restart. Log + no crash.
            Log.info("[MeetingTranscriptionEngine] mic hot-swap: step3 prepare() FAILED — 'You' channel inactive: \(error.localizedDescription)")
            return
        }

        // Step 4: Wire the fresh transcriber into the holder BEFORE the stream swap
        // delivers new-device buffers (RecordingCore awaits this entire callback first).
        Log.info("[MeetingTranscriptionEngine] mic hot-swap: step4 — wiring new transcriber into holder and starting")
        holder.setMic(newMic)
        newMic.start()
        Log.info("[MeetingTranscriptionEngine] mic hot-swap: step4 complete — fresh 'You' ChannelTranscriber ready for new device")
    }

    // MARK: - Start transcription

    /// Start two ChannelTranscribers for the given session directory.
    ///
    /// - Parameter sessionDir: The meeting session directory. conversation.jsonl is
    ///   written here in the meeting session directory.
    /// - Throws: `TranscriptionEngineError` if the speech model is unavailable.
    ///   The caller (MeetingTranscriptionService.start) propagates this error loud.
    ///
    /// ## Fixture mode (AC21)
    ///
    /// If `WORK42_MEETING_FIXTURE_WAV` is set in the process environment, the
    /// method runs entirely without the live SCStream:
    ///
    ///   1. The ChannelTranscribers are created, prepared, and started as normal.
    ///   2. A `FixtureWAVFeeder` reads the canned WAV, splits channels, and feeds
    ///      `AVAudioPCMBuffer`s via `ingestPCM(_:at:)` in real-time cadence.
    ///   3. `MeetingTranscriptionService.start()` is NOT called — no RecordingCore,
    ///      no SCStream, no screen-recording permission needed.
    ///   4. `stop()` waits for the feed task to drain, then finalizes as usual.
    ///
    /// When the env var is absent the method is identical to the pre-seam
    /// implementation: INERT — zero effect on the live path.
    @available(macOS 26.0, *)
    func start(sessionDir: URL) async throws {
        guard !isTranscribing else {
            Log.info("[MeetingTranscriptionEngine] start() while already transcribing — no-op")
            return
        }

        // ── Fixture-injection seam (AC21) ──────────────────────────────────────
        // Check WORK42_MEETING_FIXTURE_WAV before any live-path resource allocation.
        // INERT when the env var is absent.
        if let envValue = ProcessInfo.processInfo.environment["WORK42_MEETING_FIXTURE_WAV"],
           !envValue.isEmpty {
            try await startFixture(sessionDir: sessionDir, envValue: envValue)
            return
        }
        // ── End fixture seam ───────────────────────────────────────────────────

        // Fail-loud model check before allocating any resources.
        try await ChannelTranscriber.checkModelAvailability()

        let log = ConversationLog(sessionDir: sessionDir)
        conversationLog = log

        let micT = ChannelTranscriber(speaker: "You", log: log)
        let sysT = ChannelTranscriber(speaker: "Them", log: log)

        // Prepare both analyzers (format selection + model allocation).
        do {
            try await micT.prepare()
            try await sysT.prepare()
        } catch {
            lastError = error
            Log.info("[MeetingTranscriptionEngine] prepare failed: \(error.localizedDescription)")
            throw error
        }

        // Wire into the holder so the seam closures start routing buffers.
        holder.set(mic: micT, system: sysT)

        // Start analysis + result loops.
        micT.start()
        sysT.start()

        isFixtureMode  = false
        isTranscribing = true
        lastError = nil
        Log.info("[MeetingTranscriptionEngine] active — You+Them transcribers writing to \(sessionDir.path)/conversation.jsonl")
    }

    // MARK: - Fixture start (internal, macOS 26+)

    /// Start in fixture mode: feed canned WAV instead of live SCStream buffers.
    /// Called from start() when WORK42_MEETING_FIXTURE_WAV is set.
    @available(macOS 26.0, *)
    private func startFixture(sessionDir: URL, envValue: String) async throws {
        Log.info("[MeetingTranscriptionEngine] FIXTURE MODE: WORK42_MEETING_FIXTURE_WAV=\(envValue)")

        guard let feeder = FixtureWAVFeeder(envValue: envValue) else {
            // env var is set but path is invalid — fail loud so the user sees it.
            throw TranscriptionEngineError.speechModelUnavailable(
                "WORK42_MEETING_FIXTURE_WAV is set to '\(envValue)' but the file(s) could not be found. " +
                "Provide a valid path to a stereo WAV or two mono WAVs separated by a colon."
            )
        }

        // Model check still applies in fixture mode — SpeechTranscriber must be ready.
        try await ChannelTranscriber.checkModelAvailability()

        let log = ConversationLog(sessionDir: sessionDir)
        conversationLog = log

        let micT = ChannelTranscriber(speaker: "You",  log: log)
        let sysT = ChannelTranscriber(speaker: "Them", log: log)

        do {
            try await micT.prepare()
            try await sysT.prepare()
        } catch {
            lastError = error
            Log.info("[MeetingTranscriptionEngine] fixture prepare failed: \(error.localizedDescription)")
            throw error
        }

        // Wire the holder so that any live SCStream closures (if somehow called)
        // still route correctly — though in fixture mode no SCStream is opened.
        holder.set(mic: micT, system: sysT)

        micT.start()
        sysT.start()

        isFixtureMode  = true
        isTranscribing = true
        lastError      = nil

        Log.info("[MeetingTranscriptionEngine] fixture mode active — feeding \(feeder.isStereo ? "stereo" : "two-mono") WAV → \(sessionDir.path)/conversation.jsonl")

        // Launch the feed task. We hold a reference so stop() can await it.
        let feedTask = Task(priority: .userInitiated) {
            await feeder.feed(micT: micT, systemT: sysT)
        }
        fixtureTask = feedTask
    }

    // MARK: - Stop transcription

    /// Stop both ChannelTranscribers and finalize the conversation log.
    ///
    /// In fixture mode, waits for the WAV feed task to complete before
    /// finalizing so all buffered audio is processed and written to
    /// conversation.jsonl before the analyzers are torn down.
    @available(macOS 26.0, *)
    func stop() async {
        guard isTranscribing else {
            Log.info("[MeetingTranscriptionEngine] stop() while not transcribing — no-op")
            return
        }
        isTranscribing = false

        // In fixture mode, wait for the feed task to finish (it may still be
        // streaming audio) before tearing down the transcriberss.
        if let feedTask = fixtureTask {
            fixtureTask = nil
            Log.info("[MeetingTranscriptionEngine] waiting for fixture feed task to complete…")
            await feedTask.value
        }

        let (micT, sysT) = holder.take()
        if let m = micT { await m.stop() }
        if let s = sysT { await s.stop() }

        isFixtureMode  = false
        // Deliberately KEEP conversationLog after stop (it's replaced on the
        // next start). SpeakerDiarizationService's stop-time flush() runs
        // AFTER this engine stops (MeetingTranscriptionService.stop ordering)
        // and back-patches labels through rewriteSpeakerLabels(_:) — nil-ing
        // the log here would silently drop the final window's patches. Safe:
        // no appends can occur post-stop (transcribers are torn down), so the
        // retained actor only ever serves rewrites until the next session.
        Log.info("[MeetingTranscriptionEngine] stopped — conversation.jsonl finalized")
    }

    // MARK: - Speaker-label patching (diarization back-patch route)

    /// Route a batch of speakerLabel patches through the session's ONE
    /// canonical ConversationLog actor. This is the only supported way for
    /// out-of-engine code (SpeakerDiarizationService's re-cluster passes,
    /// the transcript UI's corrections) to modify conversation.jsonl —
    /// creating a second ConversationLog on the same file would let an
    /// append (FileHandle seekToEnd in one actor) interleave with an
    /// atomic-rename rewrite (in the other) and drop the appended line.
    /// A `nil` value clears that line's label. No-op with a log line when
    /// no session has started yet.
    func rewriteSpeakerLabels(_ updates: [String: String?]) async {
        guard let log = conversationLog else {
            Log.info("[MeetingTranscriptionEngine] rewriteSpeakerLabels: no conversation log yet — dropped \(updates.count) updates")
            return
        }
        await log.rewriteSpeakerLabels(updates)
    }
}
