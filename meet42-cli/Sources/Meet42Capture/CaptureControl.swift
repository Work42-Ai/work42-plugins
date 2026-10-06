// CaptureControl.swift — public facade over the meeting-capture engine for
// the meet42 CLI (meet42-plugin-conversion, M1/s9).
//
// `MeetingTranscriptionEngine` and `SpeakerDiarizationService` are module-
// internal singletons (they expose a lot of `@Observable` / fixture / hot-
// swap surface that the CLI has no business touching). The `meet42` executable
// lives in a separate target, so it needs a small public seam to drive the
// three lifecycle calls it actually uses: wire the transcription taps, start
// transcription for a session dir, and stop. Diarization is driven the same
// way. Keeping the facade here (rather than making the engine itself public)
// keeps the engine's wide internal API out of the package's public surface.

import Foundation

@MainActor
public enum MeetingCapture {

    // MARK: - Transcription engine

    /// Wire the live mic / system-audio taps into the transcription engine.
    /// Call once before `transcriptionStart`.
    public static func transcriptionSetup() {
        MeetingTranscriptionEngine.shared.setup()
    }

    /// Start two-channel ("You" / "Them") transcription for `sessionDir`.
    /// Writes `conversation.jsonl` under the session directory. On-device
    /// transcription (SpeechAnalyzer) requires macOS 26+; on older systems
    /// this is a no-op (audio capture + diarization still run).
    public static func transcriptionStart(sessionDir: URL) async throws {
        if #available(macOS 26.0, *) {
            try await MeetingTranscriptionEngine.shared.start(sessionDir: sessionDir)
        } else {
            Log.info("[MeetingCapture] transcription needs macOS 26+ — skipping")
        }
    }

    /// Finalize and tear down transcription (flushes pending lines).
    public static func transcriptionStop() async {
        if #available(macOS 26.0, *) {
            await MeetingTranscriptionEngine.shared.stop()
        }
    }

    // MARK: - Speaker diarization

    /// Start on-device speaker diarization for `sessionDir` / `sessionId`.
    /// Best-effort: never throws (unavailable models leave the session
    /// unlabeled).
    public static func diarizationStart(sessionDir: URL, sessionId: String) async {
        await SpeakerDiarizationService.shared.start(
            sessionDir: sessionDir, sessionId: sessionId
        )
    }

    /// Stop diarization for `sessionId` (flushes the final window).
    public static func diarizationStop(sessionId: String) async {
        await SpeakerDiarizationService.shared.stop(sessionId: sessionId)
    }
}
