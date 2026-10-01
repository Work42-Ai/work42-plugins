// SpeakerDiarizationService.swift — Rolling on-device speaker diarization
// over a meeting's merged system-audio ("Them") stream.
//
// Sibling service to MeetingTranscriptionService, started/stopped from
// MeetingTranscriptionService.start(session:)/stop(session:) (the single
// choke point both call — there are multiple outer call sites across
// AppShell/MeetingScheduler, all of which funnel through those two methods,
// so hooking there covers every caller without duplicating wiring).
//
// Taps RecordingCore's .audio buffer stream via its OWN handler registration
// (RecordingCore fans out to every registered handler independently — this
// does not steal buffers from MeetingTranscriptionEngine, which has its own
// separate registration for the same stream).
//
// Retains the session's audio in memory (capped at 30 min; NEVER written
// to disk) and re-diarizes the FULL retained audio every ~30s via
// FluidAudio's offline pipeline — the configuration its accuracy
// benchmarks actually measure. Each pass supersedes the last: labels are
// assigned conservatively (a speaker needs >= 2 segments before it earns a
// "Speaker N" — a wrong label is worse than no label) and conversation.jsonl
// is back-patched through MeetingTranscriptionEngine.rewriteSpeakerLabels
// so earlier lines converge on the corrected identities. See
// DiarizationWorker's doc comment for why full-audio passes replaced the
// original independent-10s-window design (fix subtasks .8/.9 of
// feat/event-sessions-update-to-summary-and-transcribe).
//
// <sessionDir>/speaker-segments.jsonl is a full atomic snapshot of the
// latest pass — timing + small embedding vectors, never raw audio,
// matching the rest of the meeting pipeline (RecordingCore/
// MeetingTranscriptionEngine never write audio to disk either). Its one
// downstream consumer is the meeting-end attribution prompt
// (speaker_segments_path).

@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio
import Foundation
import Meet42Kit

// MARK: - SpeakerSegmentLine

/// One line in speaker-segments.jsonl.
private nonisolated struct SpeakerSegmentLine: Encodable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let voiceId: String
    let embedding: [Float]
    let confidence: Double
}

// MARK: - SpeakerSegmentLog

/// Writer for <sessionDir>/speaker-segments.jsonl. Since the diarizer now
/// re-derives ALL segments from the full session audio on every pass, the
/// file is a full atomic snapshot of the latest pass (not an append log) —
/// which is exactly what its one downstream consumer, the meeting-end
/// attribution prompt (speaker_segments_path), wants to read.
private actor SpeakerSegmentLog {
    private let fileURL: URL
    private let encoder: JSONEncoder

    init(sessionDir: URL) {
        self.fileURL = sessionDir.appendingPathComponent("speaker-segments.jsonl")
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = enc
    }

    func replaceAll(_ lines: [SpeakerSegmentLine]) {
        do {
            var data = Data()
            for line in lines {
                data.append(try encoder.encode(line))
                data.append(0x0A) // newline
            }
            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.info("[SpeakerSegmentLog] replaceAll error: \(error.localizedDescription)")
        }
    }
}

// MARK: - DiarizationWorker

/// Owns one session's diarization: retains the session's audio (capped),
/// re-diarizes the FULL retained audio on a fixed cadence via FluidAudio's
/// offline pipeline, back-patches conversation.jsonl after each pass, and
/// answers overlap queries for the live-tagging path (.4).
///
/// WHY full-audio passes instead of independent 10s windows (the previous
/// design): live QA showed one consistent-sounding voice fragmenting into
/// multiple "Voices". The windows were the cause, not the audio — an
/// utterance straddling a window boundary becomes a low-activity fragment
/// in each window, yielding weak, distorted embeddings (same-voice
/// window-to-window similarities swung from 1.00 to -0.03, with FluidAudio
/// itself scoring the fragments ~0.28 quality vs ~0.73 for whole
/// utterances). Feeding the whole session per pass is the configuration
/// FluidAudio's accuracy benchmarks actually measure (proper internal
/// chunk overlap + cross-chunk speaker tracking), and it deletes the
/// hand-rolled clustering entirely — the library's own per-pass speakerIds
/// drive the labels.
///
/// Cost: a pass every ~30s over up to 30 min of retained audio; FluidAudio
/// runs ~300x real-time on Apple silicon, so the worst-case pass is a few
/// seconds inside this actor — never on the main thread.
@available(macOS 26.0, *)
private actor DiarizationWorker {
    /// Re-diarize after this much NEW audio accumulates (~30s). Live labels
    /// can lag by up to this much; back-patching heals earlier lines on
    /// every pass.
    private static let passIntervalSampleCount = 16_000 * 30

    /// Retained-audio cap: 30 minutes of 16kHz mono Float32 (~115MB).
    /// Beyond it the OLDEST samples are trimmed with `audioBaseSeconds`
    /// advanced to match, so segment times stay aligned with
    /// conversation.jsonl's audioStartSeconds timeline (the back-patch
    /// key). Lines older than the horizon keep whatever label their last
    /// covering pass gave them.
    private static let maxRetainedSampleCount = 16_000 * 60 * 30

    /// Skip passes until at least this much audio exists — FluidAudio's
    /// documented minimum viable chunk is 3-5 seconds.
    private static let minPassSampleCount = 16_000 * 5

    /// A raw FluidAudio speakerId only earns a "Speaker N" display label once
    /// it has this many segments in the current pass. Spurious one-segment
    /// speakers stay unlabeled and render as plain grey "Them": a wrong
    /// label is worse than no label.
    private static let minSegmentsForLabel = 2

    private let sessionDir: URL
    private let segmentLog: SpeakerSegmentLog

    /// Known remote-attendee count from the session's meeting.json calendar
    /// snapshot, nil for ad-hoc sessions. When set, a pass can never surface
    /// MORE distinct speakers than this: surplus (least-active) speakers are
    /// merged into their nearest kept speaker by embedding centroid. A cap,
    /// not a forced count — silent attendees never cause forced splits.
    private let expectedRemoteSpeakerCount: Int?

    /// nil until `attachModels` — audio accumulates in `retainedSamples`
    /// meanwhile, so the minutes before the (cached) models finish their
    /// CoreML load still get diarized retroactively on the first pass.
    private var diarizer: DiarizerManager?

    /// All retained session audio. `audioBaseSeconds` is the
    /// session-relative time of retainedSamples[0].
    private var retainedSamples: [Float] = []
    private var audioBaseSeconds: Double = 0
    private var samplesSinceLastPass = 0

    /// Latest pass's labeled segments (session-relative seconds, same
    /// coordinate system as ConversationLine.audioStartSeconds — both
    /// anchored at capture start). label nil = speaker unqualified.
    private var segments: [(start: Double, end: Double, label: String?)] = []

    /// Raw FluidAudio speakerId -> persistent display label. FluidAudio's
    /// SpeakerManager keeps its speaker database across calls on the same
    /// DiarizerManager instance, so ids are stable across passes; each
    /// qualifies for a display number once, keyed by first qualification
    /// order, and keeps it for the session.
    private var displayLabels: [String: String] = [:]

    init(sessionDir: URL, expectedRemoteSpeakerCount: Int?) {
        self.sessionDir = sessionDir
        self.segmentLog = SpeakerSegmentLog(sessionDir: sessionDir)
        self.expectedRemoteSpeakerCount = expectedRemoteSpeakerCount
    }

    /// Attach the loaded models and run a first pass over whatever audio
    /// accumulated while they were loading. Called once, from the async
    /// model-wait Task in SpeakerDiarizationService.start().
    func attachModels(_ models: DiarizerModels) async {
        guard diarizer == nil else { return }
        let config = DiarizerConfig(
            clusteringThreshold: 0.7,
            minSpeechDuration: 1.0,
            minSilenceGap: 0.5
        )
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        diarizer = manager
        Log.info("[DiarizationWorker] models attached — first pass over \(retainedSamples.count / 16_000)s of audio")
        await runPassIfReady(force: true)
    }

    /// Feed one buffer's worth of 16kHz mono Float32 samples.
    func ingest(_ samples: [Float]) async {
        retainedSamples.append(contentsOf: samples)
        samplesSinceLastPass += samples.count

        let excess = retainedSamples.count - Self.maxRetainedSampleCount
        if excess > 0 {
            retainedSamples.removeFirst(excess)
            audioBaseSeconds += Double(excess) / 16_000.0
            Log.info("[DiarizationWorker] trimmed \(excess / 16_000)s beyond the 30-min retention horizon")
        }

        if samplesSinceLastPass >= Self.passIntervalSampleCount {
            await runPassIfReady(force: false)
        }
    }

    /// Final pass at session end so the tail (< one pass interval) isn't
    /// left unlabeled.
    func flush() async {
        await runPassIfReady(force: true)
    }

    private func runPassIfReady(force: Bool) async {
        guard let diarizer else { return }
        guard retainedSamples.count >= Self.minPassSampleCount else { return }
        guard force || samplesSinceLastPass >= Self.passIntervalSampleCount else { return }
        samplesSinceLastPass = 0

        let result: DiarizationResult
        do {
            result = try diarizer.performCompleteDiarization(
                retainedSamples, sampleRate: 16_000, atTime: audioBaseSeconds
            )
        } catch {
            Log.info("[DiarizationWorker] full-audio pass failed: \(error.localizedDescription)")
            return
        }

        // Qualify speakers by segment count, then map raw speakerIds to
        // persistent display labels in first-qualification order.
        var counts: [String: Int] = [:]
        var firstSeen: [String: Double] = [:]
        for seg in result.segments {
            counts[seg.speakerId, default: 0] += 1
            let start = Double(seg.startTimeSeconds)
            if firstSeen[seg.speakerId].map({ start < $0 }) ?? true {
                firstSeen[seg.speakerId] = start
            }
        }
        var qualified = counts.filter { $0.value >= Self.minSegmentsForLabel }.keys
            .sorted { (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0) }

        // Attendee cap: when the calendar snapshot says how many remote
        // people are in this meeting, a pass can never surface more distinct
        // speakers than that. Surplus speakers — the LEAST active ones, most
        // likely over-segmentation artifacts — are remapped onto their
        // nearest kept speaker by embedding centroid, so their lines inherit
        // the kept speaker's label instead of minting a phantom person.
        var remappedBuild: [String: String] = [:]  // surplus rawId -> kept rawId
        if let cap = expectedRemoteSpeakerCount, qualified.count > cap, cap > 0 {
            let byActivity = qualified.sorted { counts[$0, default: 0] > counts[$1, default: 0] }
            let kept = Array(byActivity.prefix(cap))
            let surplus = byActivity.dropFirst(cap)

            var centroids: [String: [Float]] = [:]
            for id in qualified {
                let embs = result.segments.filter { $0.speakerId == id }.map { $0.embedding }
                guard let first = embs.first else { continue }
                var sum = first
                for e in embs.dropFirst() {
                    for i in sum.indices where i < e.count { sum[i] += e[i] }
                }
                let n = Float(embs.count)
                centroids[id] = sum.map { $0 / n }
            }
            func cosine(_ a: [Float], _ b: [Float]) -> Float {
                guard a.count == b.count, !a.isEmpty else { return 0 }
                var dot: Float = 0, na: Float = 0, nb: Float = 0
                for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
                guard na > 0, nb > 0 else { return 0 }
                return dot / (na.squareRoot() * nb.squareRoot())
            }
            for id in surplus {
                guard let c = centroids[id] else { continue }
                let nearest = kept.max { cosine(centroids[$0] ?? [], c) < cosine(centroids[$1] ?? [], c) }
                if let nearest { remappedBuild[id] = nearest }
            }
            qualified = kept.sorted { (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0) }
            Log.info("[DiarizationWorker] attendee cap \(cap): merged \(remappedBuild.count) surplus speaker(s) into nearest kept")
        }
        // Frozen copy: the nested effectiveId function must capture an
        // immutable value or strict concurrency flags a data-race risk when
        // downstream maps cross into child tasks.
        let remapped = remappedBuild

        for rawId in qualified where displayLabels[rawId] == nil {
            displayLabels[rawId] = "Speaker \(displayLabels.count + 1)"
        }

        // Resolve a segment's effective raw id through the surplus remap.
        func effectiveId(_ rawId: String) -> String { remapped[rawId] ?? rawId }

        segments = result.segments.map { seg in
            let id = effectiveId(seg.speakerId)
            return (
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                label: qualified.contains(id) ? displayLabels[id] : nil
            )
        }

        // Snapshot the sidecar (full replace — this pass supersedes all
        // earlier ones; the meeting-end attribution prompt reads this file).
        let sidecarLines = result.segments.map { seg in
            let id = effectiveId(seg.speakerId)
            return SpeakerSegmentLine(
                startSeconds: Double(seg.startTimeSeconds),
                endSeconds: Double(seg.endTimeSeconds),
                voiceId: qualified.contains(id)
                    ? (displayLabels[id] ?? "unassigned")
                    : "unassigned",
                embedding: seg.embedding,
                confidence: Double(seg.qualityScore)
            )
        }
        let log = segmentLog
        Task { await log.replaceAll(sidecarLines) }

        Log.info("[DiarizationWorker] pass complete: \(result.segments.count) segments, \(qualified.count) qualified voice(s)")
        await backPatchConversation()
    }

    /// Reconcile conversation.jsonl with the latest pass: every Them line
    /// whose spoken-audio interval overlaps a segment gets that segment's
    /// label (max-overlap wins); lines whose current label differs —
    /// including previously-labeled lines a new pass re-attributed — are
    /// patched in ONE batch through the engine's canonical ConversationLog.
    private func backPatchConversation() async {
        // Snapshot into a Sendable value and do the parse + diff on the
        // MainActor: TranscriptLine's properties are MainActor-isolated
        // under this package's default isolation (xcodebuild's Release
        // config enforces this; the SwiftPM debug build is laxer). The
        // transcript tile already parses this same file on the main thread
        // every 500ms, so one more parse per ~30s pass is well within the
        // established budget.
        let snapshot = segments
        let horizonStart = audioBaseSeconds
        let dirPath = sessionDir.path
        let updates: [String: String?] = await MainActor.run {
            var updates: [String: String?] = [:]
            for line in parseConversation(sessionDir: dirPath) {
                guard case .speaker(let l) = line,
                      l.speaker == .them,
                      let id = l.persistentId,
                      let start = l.audioStartSeconds,
                      let end = l.audioEndSeconds
                else { continue }
                // Lines fully before the retention horizon keep their last
                // assigned label — this pass has no audio for them.
                guard end > horizonStart else { continue }
                var bestOverlap = 0.0
                var want: String?
                for seg in snapshot {
                    let overlap = min(end, seg.end) - max(start, seg.start)
                    guard overlap > 0, overlap > bestOverlap else { continue }
                    bestOverlap = overlap
                    want = seg.label
                }
                if want != l.speakerLabel {
                    updates[id] = want
                }
            }
            return updates
        }
        guard !updates.isEmpty else { return }
        await MeetingTranscriptionEngine.shared.rewriteSpeakerLabels(updates)
    }

    /// voiceId(s) whose diarized segment overlaps [start, end]
    /// (session-relative seconds). Empty when no pass has covered this
    /// interval yet (passes run every ~30s — back-patching fills those
    /// lines in) or when the covering speaker hasn't qualified for a label.
    func voiceIds(overlapping start: Double, end: Double) -> [String] {
        var bestOverlap = 0.0
        var bestLabel: String?
        for seg in segments {
            let overlap = min(end, seg.end) - max(start, seg.start)
            guard overlap > 0, overlap > bestOverlap else { continue }
            bestOverlap = overlap
            bestLabel = seg.label
        }
        return bestLabel.map { [$0] } ?? []
    }
}

// MARK: - SpeakerDiarizationService

/// @MainActor singleton, sibling to MeetingTranscriptionService. Ungated
/// (like MeetingTranscriptionService) — internally checks
/// `#available(macOS 26.0, *)` before touching FluidAudio/DiarizationWorker,
/// consistent with the rest of the meeting-transcription feature's macOS
/// floor (FluidAudio itself only requires macOS 14, but gating diarization
/// to the same floor as transcription keeps the feature's availability
/// story simple — it never "half-works" without transcription).
@MainActor
final class SpeakerDiarizationService {
    static let shared = SpeakerDiarizationService()

    private init() {}

    private var systemAudioToken: SubscriptionToken?
    /// Stored as AnyObject so this property itself needs no @available
    /// annotation — mirrors TranscriberHolder's AnyObject? + typed-cast
    /// pattern in MeetingTranscriptionEngine.swift.
    private var worker: AnyObject?

    /// Start diarization for the given session. Idempotent — a second call
    /// while already active is a no-op (best-effort service; unlike
    /// MeetingTranscriptionService.start it never throws).
    ///
    /// The audio tap registers IMMEDIATELY (the worker accumulates from the
    /// first buffer) while the models are awaited asynchronously with a
    /// bounded wait — the cached-model CoreML load takes a few seconds on a
    /// fresh app process, and the old instant readiness check lost that
    /// race, silently disabling diarization for the first session after
    /// every launch. Once models attach, the accumulated backlog is
    /// diarized and back-patched, so even the opening minute gets labels.
    /// Only a genuinely unavailable model (first-ever ~100MB download still
    /// in flight past the deadline, or a failed download) leaves the
    /// session unlabeled — AC4's graceful skip, correctly scoped.
    func start(sessionDir: URL, sessionId: String) async {
        guard #available(macOS 26.0, *) else { return }
        guard worker == nil else {
            Log.info("[SpeakerDiarizationService] start() while already active — no-op")
            return
        }

        // Attendee cap from the calendar snapshot, when this session has one
        // (calendar-driven meetings write meeting.json at mint; ad-hoc event
        // sessions have none -> nil -> uncapped). Count remote attendees
        // only — the local user is the "You" channel, never a "Them" speaker.
        let expectedRemote: Int? = MeetingMeta.read(sessionDir: sessionDir.path).map { file in
            let remote = file.event.attendees.filter { !$0.isCurrentUser }.count
            return remote > 0 ? remote : file.event.attendees.count
        }.flatMap { $0 > 0 ? $0 : nil }
        if let expectedRemote {
            Log.info("[SpeakerDiarizationService] attendee cap from meeting.json: \(expectedRemote) remote speaker(s)")
        }

        let newWorker = DiarizationWorker(sessionDir: sessionDir, expectedRemoteSpeakerCount: expectedRemote)
        worker = newWorker

        // Capture newWorker (an actor reference — Sendable) directly rather
        // than looking up `self.worker` per buffer, so the hot audio path
        // never needs a @MainActor hop.
        let token = RecordingCore.shared.addSystemAudioHandler { buf in
            guard let floats = AudioFloatExtraction.floatSamples(from: buf) else { return }
            Task { await newWorker.ingest(floats) }
        }
        systemAudioToken = token

        Task {
            if let models = await DiarizationModelStatus.shared.awaitModels(timeoutSeconds: 60) {
                // Benign orphan case: if the session stopped before the
                // models arrived, this attaches to a worker whose tap is
                // already removed — the backlog drain back-patches through
                // the engine's retained log (fine post-meeting) or logs
                // "no matching lineIds" if a new session replaced it.
                await newWorker.attachModels(models)
                Log.info("[SpeakerDiarizationService] diarization active for session=\(sessionId)")
            } else {
                Log.info("[SpeakerDiarizationService] models unavailable — session=\(sessionId) runs unlabeled (AC4)")
            }
        }
    }

    /// Stop diarization for the given session. Safe to call even if
    /// diarization was never started for this session (no-op).
    func stop(sessionId: String) async {
        if let token = systemAudioToken {
            RecordingCore.shared.removeHandler(token)
            systemAudioToken = nil
        }
        if #available(macOS 26.0, *), let w = worker as? DiarizationWorker {
            await w.flush()
        }
        worker = nil
    }

    /// voiceId(s) whose diarized segment overlaps [start, end]
    /// (session-relative seconds — same coordinate system as
    /// ConversationLine.audioStartSeconds/audioEndSeconds). Returns an
    /// empty array when diarization isn't active for the current session
    /// (models weren't ready, or no session started) or nothing overlaps
    /// yet. Consumed by subtask .4's live speaker_label tagging.
    func voiceIds(overlapping start: Double, end: Double) async -> [String] {
        guard #available(macOS 26.0, *), let w = worker as? DiarizationWorker else { return [] }
        return await w.voiceIds(overlapping: start, end: end)
    }
}

// MARK: - AudioFloatExtraction

/// Converts a CMSampleBuffer to 16kHz mono Float32 samples for FluidAudio.
/// RecordingCore.buildStreamConfiguration already configures system-audio
/// capture at 16kHz mono, so the common case is a direct copy with no
/// resampling — but this still routes through AVAudioConverter when the
/// source format doesn't match, for the same format-agnostic safety
/// MeetingTranscriptionEngine.convertToPCM applies to the same stream.
private enum AudioFloatExtraction {
    private nonisolated static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    nonisolated static func floatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return nil }
        srcBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: srcBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        let bufferToRead: AVAudioPCMBuffer
        if srcFormat == targetFormat {
            bufferToRead = srcBuffer
        } else {
            guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else { return nil }
            let ratio = targetFormat.sampleRate / srcFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1
            guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }

            nonisolated final class InputFlag: @unchecked Sendable { var provided = false }
            let flag = InputFlag()
            var convError: NSError?
            converter.convert(to: dstBuffer, error: &convError) { _, outStatus in
                guard !flag.provided else { outStatus.pointee = .noDataNow; return nil }
                flag.provided = true
                outStatus.pointee = .haveData
                return srcBuffer
            }
            guard convError == nil, dstBuffer.frameLength > 0 else { return nil }
            bufferToRead = dstBuffer
        }

        guard let channelData = bufferToRead.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(bufferToRead.frameLength)))
    }
}
