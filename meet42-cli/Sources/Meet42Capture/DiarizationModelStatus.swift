// DiarizationModelStatus.swift — On-device FluidAudio model readiness.
//
// FluidAudio's diarization models (~100MB, pyannote segmentation +
// WeSpeaker embeddings) download from HuggingFace on first use and cache
// at ~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml.
// This type triggers that download once per app run, in the background,
// non-blocking, and exposes a synchronous-under-the-hood readiness check so
// SpeakerDiarizationService (subtask .3) can skip diarization gracefully for
// a session that starts before the download completes (AC4) — never stall
// meeting start on a ~100MB fetch, never surface an error to the user.
//
// Subtask 2 of feat/event-sessions-update-to-summary-and-transcribe.

import FluidAudio
import Foundation

/// Tracks the one download of FluidAudio's diarization models for the
/// lifetime of the app process. `ensureDownloadStarted()` is idempotent —
/// call it at the start of every meeting session; only the first call
/// actually kicks off a download.
@MainActor
final class DiarizationModelStatus {
    static let shared = DiarizationModelStatus()

    private init() {}

    private enum State {
        case notStarted
        case downloading
        case ready(DiarizerModels)
        case failed(any Error)
    }

    private var state: State = .notStarted
    private var downloadTask: Task<Void, Never>?

    /// Start the model download in the background if it hasn't already been
    /// started this app run. Safe to call every time a meeting session
    /// starts — a second call while downloading/ready/failed is a no-op.
    func ensureDownloadStarted() {
        guard downloadTask == nil else { return }
        state = .downloading
        Log.info("[DiarizationModelStatus] starting FluidAudio model download/verify")
        downloadTask = Task { [weak self] in
            do {
                let models = try await DiarizerModels.downloadIfNeeded()
                self?.state = .ready(models)
                Log.info("[DiarizationModelStatus] FluidAudio models ready")
            } catch {
                self?.state = .failed(error)
                Log.info("[DiarizationModelStatus] FluidAudio model download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Non-blocking readiness check. Does NOT await an in-flight download —
    /// returns false immediately while downloading, not yet started, or
    /// failed, so a caller can skip diarization for the CURRENT session
    /// (AC4) rather than block session start. The download (if in flight)
    /// keeps running in the background regardless of this call.
    func modelsReady() async -> Bool {
        if case .ready = state { return true }
        return false
    }

    /// Bounded wait for the models: kicks the download/load if needed and
    /// polls until ready (returns them), failed, or the deadline passes
    /// (returns nil). Exists because the instant `modelsReady()` check
    /// loses the race against the CACHED-model CoreML load on a fresh app
    /// process (a few seconds), which silently disabled diarization for the
    /// first session after every launch — the deadline still bounds the
    /// genuine first-ever ~100MB download so a session never waits forever.
    func awaitModels(timeoutSeconds: Double) async -> DiarizerModels? {
        ensureDownloadStarted()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            switch state {
            case .ready(let models): return models
            case .failed: return nil
            case .notStarted, .downloading:
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        Log.info("[DiarizationModelStatus] awaitModels timed out after \(Int(timeoutSeconds))s")
        return nil
    }

    /// The downloaded models, only when ready right now. nil otherwise —
    /// callers should treat that as "skip diarization for this session."
    func modelsIfReady() -> DiarizerModels? {
        if case .ready(let models) = state { return models }
        return nil
    }
}
