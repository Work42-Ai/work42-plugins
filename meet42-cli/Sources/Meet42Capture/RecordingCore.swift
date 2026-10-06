// RecordingCore.swift — Shared in-app recording core.
//
// The SINGLE TCC-owned recording entry point used by BOTH flow42 recording
// and MeetingTranscriptionService. Owns:
//
//   (a) Audio capture — microphone via SCStream's captureMicrophone=true,
//       delivering mic buffers (.microphone) and system-audio buffers (.audio)
//       as separate SCStreamOutputType values.
//
//   (b) SCStream — one ScreenCaptureKit stream delivering:
//         .microphone  — mic / "You" channel (16 kHz mono)
//         .audio       — system audio / "Them" channel (16 kHz mono)
//       The stream still requires an SCContentFilter (a display) because
//       macOS gates system-audio capture behind Screen-Recording permission;
//       no `.screen` (video) output is added.
//       SCStreamConfiguration + SCStream init shape copied from
//       SimulatorWindowCaptureTransport (~lines 476–574).
//
//   (c) Recording lifecycle/state — start/stop with state reported through
//       StateFile.AppState/DerivedState so both consumers observe via the
//       existing StateClient mtime-poll pipeline.
//
//   (d) Permission preflight — MicPermission.preflight() +
//       CGPreflightScreenCaptureAccess/CGRequestScreenCaptureAccess in ONE
//       place; denial returns a typed error naming mic vs screen.
//
// MULTI-SUBSCRIBER FAN-OUT API (subtask 2 refactor)
// --------------------------------------------------
// The old single-slot callbacks (`onMicBuffer`, `onSystemAudioBuffer`) have
// been replaced by a multi-subscriber model so that multiple consumers
// (e.g. SpeechTranscriber, meeting transcription) can each independently
// subscribe to the same channel without clobbering each other.
//
// Subscribe API:
//
//   let token = RecordingCore.shared.addMicHandler { buf in … }
//   let token = RecordingCore.shared.addSystemAudioHandler { buf in … }
//   RecordingCore.shared.removeHandler(token)
//
// Tokens are opaque UInt64 values returned by each addXxxHandler call.
// removeHandler(_:) is safe to call from any queue and is idempotent.
// Handlers are invoked on SCStream's internal queue (nonisolated).
// Fan-out is O(N subscribers) under NSLock — acceptable for the expected
// small N across SpeechTranscriber + future consumers.
//
// Design constraints:
//   - Runs inside the GUI process (Work42App). TCC for mic + screen-recording
//     is registered against the app's bundle identity. Screen-recording
//     permission is still required because system-audio capture is gated on it,
//     even though no video frames are captured.
//   - Swift 6.2 strict concurrency. @MainActor default isolation throughout.
//   - All logging via Log (stderr). Never print to stdout.
//
// SCStream: macOS 15+. captureMicrophone requires macOS 15+.
//
// NOTE: This core captures AUDIO ONLY (mic + system audio). The screen-video
// capture/storage pipeline (VideoWriter / TimelineWriter / FrameExtractor and
// the `.screen` stream output) was removed; only audio is delivered.

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - RecordingCore Errors

/// Typed error naming the specific denied permission + recovery guidance,
/// fulfilling AC22 (fail loud, name mic vs screen).
public enum RecordingCoreError: Error, LocalizedError, Sendable {
    /// Microphone permission denied before capture started.
    case microphoneDenied(message: String)
    /// Screen-Recording permission denied before capture started.
    case screenRecordingDenied
    /// A recording is already active; stop it before starting another.
    case alreadyRecording
    /// The SCStream failed to start.
    case streamStartFailed(underlying: any Error)
    /// A codec / configuration error prevented SCStream setup.
    case configurationFailed(String)
    /// The chosen microphone device is not currently connected.
    case microphoneDeviceUnavailable(name: String, uid: String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied(let msg):
            return "Microphone permission denied: \(msg)"
        case .screenRecordingDenied:
            return "Screen-Recording permission denied. Grant it to \"Work 42\" in System Settings → Privacy & Security → Screen Recording, then try again."
        case .alreadyRecording:
            return "A recording is already active. Stop the current recording before starting another."
        case .streamStartFailed(let e):
            return "SCStream failed to start: \(e.localizedDescription)"
        case .configurationFailed(let reason):
            return "Recording configuration failed: \(reason)"
        case .microphoneDeviceUnavailable(let name, _):
            return "Selected microphone \"\(name)\" isn't connected. Reconnect it, or choose a different input device (or System Default) in Settings → Microphone, then try again."
        }
    }
}

// MARK: - Buffer handler types

/// Per-channel buffer handlers, delivered on the SCStream's internal queue.
/// Both fire from nonisolated context — hop to @MainActor when needed.
public typealias MicBufferHandler       = @Sendable (CMSampleBuffer) -> Void
public typealias SystemAudioHandler     = @Sendable (CMSampleBuffer) -> Void

// MARK: - SubscriptionToken

/// Opaque token returned by addXxxHandler. Pass to removeHandler to unsubscribe.
public struct SubscriptionToken: Sendable, Hashable {
    let id: UInt64
    public init(_ id: UInt64) { self.id = id }
}

// MARK: - Recording state

/// The lifecycle state of an active RecordingCore session.
public enum RecordingCoreState: String, Sendable, Equatable {
    case idle
    case starting     // preflight + SCStream setup in progress
    case recording    // SCStream delivering buffers
    case stopping     // teardown in progress
}

// MARK: - Session info

/// Identifies a RecordingCore session to consumers.
public struct RecordingCoreSession: Sendable, Equatable {
    /// Arbitrary slug / label provided by the caller (flow slug, meeting id).
    public let sessionID: String
    /// The root directory where session artifacts (audio/, etc.) will be written.
    public let sessionDir: URL
    /// Recording kind written into `RecordingInfo` in state.json. "learn" for
    /// flow42 learn sessions; "meeting" for MeetingTranscriptionService captures.
    /// Defaults to "learn" so existing callers are unchanged.
    public let kind: String

    public init(sessionID: String, sessionDir: URL, kind: String = "learn") {
        self.sessionID = sessionID
        self.sessionDir = sessionDir
        self.kind = kind
    }
}

// MARK: - RecordingCore

/// The single shared in-app recording core.
///
/// Consumers (flow42 recording, MeetingTranscriptionService) call `start(session:)`
/// and register per-channel handlers before the stream fires.
///
/// ## Multi-subscriber fan-out
///
/// Use `addMicHandler(_:)` and `addSystemAudioHandler(_:)` to subscribe; each
/// returns a `SubscriptionToken`. Call `removeHandler(_:)` when done. Multiple
/// subscribers per channel are supported concurrently.
///
/// Example:
/// ```swift
/// let t = RecordingCore.shared.addMicHandler { buf in … }
/// // later:
/// RecordingCore.shared.removeHandler(t)
/// ```
///
/// The core reports state through `StateFile`/`DerivedState` so the existing
/// `StateClient` mtime-poll pipeline continues to drive UI (EdgeGlowView, recording glow).
///
/// All public methods are `@MainActor`. The SCStream delegate methods are
/// `nonisolated` as required by SCStream's internal queue.
@MainActor
public final class RecordingCore: NSObject, @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = RecordingCore()

    private override init() {
        super.init()
    }

    // MARK: - State

    private(set) public var state: RecordingCoreState = .idle
    private(set) public var activeSession: RecordingCoreSession?

    // MARK: - Multi-subscriber handler storage
    //
    // All subscriber dictionaries and the token counter are accessed exclusively
    // under streamLock (same lock guarding _stream), matching the nonisolated(unsafe)
    // pattern used by SimulatorWindowCaptureTransport.
    //
    // Handlers are stored as [token: handler] dictionaries so O(1) removal.
    // Fan-out iterates the values() snapshot while NOT holding the lock to avoid
    // deadlocking if a handler itself calls removeHandler.

    private nonisolated(unsafe) var _nextToken: UInt64 = 1

    private nonisolated(unsafe) var _micHandlers:         [UInt64: MicBufferHandler]    = [:]
    private nonisolated(unsafe) var _systemAudioHandlers: [UInt64: SystemAudioHandler]  = [:]

    // MARK: - Subscribe / unsubscribe API

    /// Subscribe to `.microphone` sample buffers (mic / "You").
    ///
    /// - Parameter handler: Called on the SCStream internal queue.
    /// - Returns: A token. Pass to `removeHandler(_:)` to unsubscribe.
    public func addMicHandler(_ handler: @escaping MicBufferHandler) -> SubscriptionToken {
        let token = streamLock.withLock { () -> UInt64 in
            let id = _nextToken
            _nextToken &+= 1
            _micHandlers[id] = handler
            return id
        }
        return SubscriptionToken(token)
    }

    /// Subscribe to `.audio` (system audio / "Them") sample buffers.
    ///
    /// - Parameter handler: Called on the SCStream internal queue.
    /// - Returns: A token. Pass to `removeHandler(_:)` to unsubscribe.
    public func addSystemAudioHandler(_ handler: @escaping SystemAudioHandler) -> SubscriptionToken {
        let token = streamLock.withLock { () -> UInt64 in
            let id = _nextToken
            _nextToken &+= 1
            _systemAudioHandlers[id] = handler
            return id
        }
        return SubscriptionToken(token)
    }

    /// Unsubscribe a handler previously registered via addXxxHandler.
    ///
    /// Idempotent and safe to call from any queue (including the SCStream queue
    /// and deinit). Silently ignores unknown tokens.
    ///
    /// `nonisolated` so that a subscriber's deinit can call this without hopping
    /// to @MainActor — the implementation only touches nonisolated(unsafe) state
    /// under streamLock.
    nonisolated public func removeHandler(_ token: SubscriptionToken) {
        streamLock.withLock {
            _micHandlers.removeValue(forKey: token.id)
            _systemAudioHandlers.removeValue(forKey: token.id)
        }
    }

    // MARK: - Internal SCStream state

    // nonisolated(unsafe) + NSLock pattern matches SimulatorWindowCaptureTransport.
    private let streamLock = NSLock()
    private nonisolated(unsafe) var _stream: SCStream?
    // Saved SCContentFilter from the most recent start(), used by the hot-swap
    // rebuild fallback in applySelectedMicrophoneDevice() so we can re-create
    // the SCStream without calling SCShareableContent again.
    private nonisolated(unsafe) var _contentFilter: SCContentFilter?

    // Buffer-in smoke counters (one per channel), guarded by streamLock.
    private nonisolated(unsafe) var _micBufferCount: Int = 0
    private nonisolated(unsafe) var _audioBufferCount: Int = 0

    // MARK: - Permission preflight (centralised, AC22)

    /// Preflight both mic and screen-recording permissions before starting capture.
    /// Returns a typed `RecordingCoreError` naming the specific denied permission
    /// if either check fails. Fulfils AC22: fail loud, name mic vs screen.
    public func preflightPermissions() async -> RecordingCoreError? {
        // Both checks route through the unified Permissions catalog
        // (Permission, Flow42Core) — the SAME single implementation the
        // GUI authority PermissionsManager delegates to. RecordingCore can't
        // import Work42App (it ships in Flow42Core and is consumed by the
        // flow42 CLI too), so it talks to the catalog directly rather than
        // to PermissionsManager.shared; the prompt mechanics are identical.
        // RecordingCore runs in the foreground GUI process, so firing the
        // catalog's prompts here satisfies the GUI-only-request rule.

        // 1. Mic
        if case .denied(let msg) = await Permission.microphone.preflight() {
            return .microphoneDenied(message: msg)
        }

        // 2. Screen Recording
        if case .denied = await Permission.screenRecording.preflight() {
            return .screenRecordingDenied
        }

        return nil
    }

    // MARK: - Start

    /// Start the shared recording core for a new session.
    ///
    /// - Parameter session: Identifies the session (slug + dir).
    /// - Throws: `RecordingCoreError` if already recording, permission denied, or
    ///           SCStream fails to start.
    ///
    /// On success the state transitions `idle → recording` and the
    /// `StateFile.AppState` is updated so `StateClient` observers (EdgeGlowView etc.)
    /// see the change immediately.
    ///
    /// Downstream consumers (e.g. SpeechTranscriber) register their
    /// handlers via `addMicHandler`/`addSystemAudioHandler` before calling this.
    public func start(session: RecordingCoreSession) async throws {
        guard state == .idle else {
            throw RecordingCoreError.alreadyRecording
        }

        state = .starting
        Log.info("[RecordingCore] starting session=\(session.sessionID) dir=\(session.sessionDir.path)")

        // Preflight permissions (AC22).
        if let err = await preflightPermissions() {
            state = .idle
            Log.info("[RecordingCore] permission denied: \(err.localizedDescription)")
            throw err
        }

        // Resolve mic device selection (AC5 / AC6 / AC7).
        // If a specific device is selected but unavailable, fail loud now rather
        // than silently capturing the wrong (or empty) mic channel.
        let sel = MicInputDeviceStore.selected()
        let micDeviceID: String?
        if let sel {
            let available = MicInputDeviceStore.availableDevices()
            if !available.contains(where: { $0.uid == sel.uid }) {
                state = .idle
                throw RecordingCoreError.microphoneDeviceUnavailable(name: sel.name, uid: sel.uid)
            }
            micDeviceID = sel.uid
        } else {
            micDeviceID = nil
        }

        // Build SCStreamConfiguration.
        let config = buildStreamConfiguration(micDeviceID: micDeviceID)

        // Build SCContentFilter — a display is REQUIRED even though we capture
        // no video: macOS gates system-audio capture behind a display content
        // filter + Screen-Recording permission. We never add a `.screen` output,
        // so no frames are delivered.
        let filter: SCContentFilter
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                state = .idle
                throw RecordingCoreError.configurationFailed("No display found for SCStream")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        } catch let e as RecordingCoreError {
            state = .idle
            throw e
        } catch {
            state = .idle
            throw RecordingCoreError.configurationFailed("SCShareableContent unavailable: \(error.localizedDescription)")
        }

        // Create and start the SCStream. AUDIO ONLY — we add `.audio` (system
        // audio) + `.microphone` outputs but intentionally NO `.screen` output,
        // so the stream delivers no video frames.
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: nil)
        } catch {
            state = .idle
            throw RecordingCoreError.configurationFailed("addStreamOutput failed: \(error.localizedDescription)")
        }

        do {
            try await stream.startCapture()
        } catch {
            state = .idle
            throw RecordingCoreError.streamStartFailed(underlying: error)
        }

        streamLock.withLock {
            _stream = stream
            _contentFilter = filter
        }
        activeSession = session
        state = .recording

        // Persist state so StateClient observers (EdgeGlowView, recording glow) react.
        reportStateToStateFile(session: session)

        Log.info("[RecordingCore] SCStream started — delivering .microphone / .audio buffers (audio only)")
    }

    // MARK: - Stop

    /// Stop the active recording session.
    ///
    /// Idempotent: calling stop when already idle is a no-op.
    /// Transitions state back to `idle` and clears the `StateFile` entry.
    @discardableResult
    public func stop() async -> RecordingCoreSession? {
        guard state == .recording || state == .starting else {
            Log.info("[RecordingCore] stop() called while state=\(state.rawValue) — no-op")
            return nil
        }

        let session = activeSession
        state = .stopping
        Log.info("[RecordingCore] stopping session=\(session?.sessionID ?? "<none>")")

        let s: SCStream? = streamLock.withLock {
            let existing = _stream
            _stream = nil
            _contentFilter = nil
            return existing
        }

        if let s {
            do {
                try await s.stopCapture()
            } catch {
                Log.info("[RecordingCore] stopCapture error (ignored): \(error.localizedDescription)")
            }
        }

        let counts = streamLock.withLock {
            (_micBufferCount, _audioBufferCount)
        }
        Log.info("[RecordingCore] stopped — mic=\(counts.0) sysaudio=\(counts.1) buffers")

        activeSession = nil
        state = .idle

        // Clear state.json so the glow reverts to idle.
        clearStateFile()

        return session
    }

    // MARK: - Smoke path diagnostics

    /// Returns buffer counts received since the last start, keyed by channel.
    /// Useful for a smoke test: start, wait briefly, confirm both audio channels fired.
    public var bufferCounts: (mic: Int, systemAudio: Int) {
        streamLock.withLock { (_micBufferCount, _audioBufferCount) }
    }

    // MARK: - SCStreamConfiguration

    /// Build the SCStreamConfiguration for the shared recording stream.
    ///
    /// - Parameter micDeviceID: The `AVCaptureDevice.uniqueID` of the mic to pin,
    ///   or `nil` to leave `microphoneCaptureDeviceID` unset (System Default).
    ///
    /// captureMicrophone = true → .microphone sample buffers delivered separately.
    /// capturesAudio = true     → .audio (system audio) sample buffers.
    /// Both mic and system audio are delivered as separate SCStreamOutputType values.
    ///
    /// AUDIO ONLY: no `.screen` output is added, so the video-related config
    /// settings are unnecessary and have been removed.
    private func buildStreamConfiguration(micDeviceID: String?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        // Audio channels — the key property that enables mic + system audio.
        config.capturesAudio            = true
        config.captureMicrophone        = true

        // Audio format: 16 kHz mono — what SpeechTranscriber expects downstream.
        config.sampleRate               = 16_000
        config.channelCount             = 1

        // Pin the mic device when a specific selection is persisted (AC5 / AC6).
        // microphoneCaptureDeviceID is NSString? (SCStream.h:363); nil = System Default.
        if let uid = micDeviceID {
            config.microphoneCaptureDeviceID = uid
            let name = MicInputDeviceStore.availableDevices()
                .first(where: { $0.uid == uid })?.name ?? uid
            Log.info("[RecordingCore] mic device pinned: \(name) (\(uid))")
        } else {
            Log.info("[RecordingCore] mic device: System Default")
        }

        return config
    }

    // MARK: - Mic device change notification hook

    /// Called on @MainActor just before a live mic hot-swap reconfigures the SCStream's
    /// mic device. Consumers that maintain state tied to a specific mic audio timeline
    /// (e.g. MeetingTranscriptionEngine's SpeechAnalyzer sessions) register here to
    /// finalize their current session and start a fresh one before the new device's
    /// buffers arrive.
    ///
    /// Set by MeetingTranscriptionEngine.setup() in the GUI process.
    /// nil in the flow42 CLI daemon (which has no SpeechAnalyzer to reset).
    ///
    /// WHY THIS HOOK EXISTS:
    /// Apple's Speech framework (SpeechAnalyzer / SpeechRecognizerWorker) hard-traps
    /// (EXC_BREAKPOINT in SpeechRecognizerWorker.preRunRecognition) when it receives
    /// audio from a different physical mic device on the same long-lived session.
    /// The fix is to finalize the old SpeechAnalyzer session and start a fresh one
    /// coordinated with the SCStream device swap — this hook is the coordination point.
    public var onMicDeviceWillChange: (@MainActor () async -> Void)?

    // MARK: - Live mic hot-swap (AC8 / AC10 / AC11)

    /// Apply the currently-persisted microphone selection to the active recording stream.
    ///
    /// - If a specific device is selected but not connected, throws
    ///   `RecordingCoreError.microphoneDeviceUnavailable` (AC10: caller decides how to
    ///   surface the warning — never kills the active meeting).
    /// - If no recording is active (`state != .recording`), returns without error;
    ///   the next `start()` call will read the store fresh.
    /// - When recording: notifies `onMicDeviceWillChange` observers first (so
    ///   MeetingTranscriptionEngine can finalize/reset its SpeechAnalyzer before the
    ///   device swap), then calls `SCStream.updateConfiguration(_:)` on the live stream
    ///   (gap-free mic switch without stopping capture, AC8).
    /// - Fallback: if `updateConfiguration` throws, stops the current SCStream, creates
    ///   a new one with the updated config using the saved `SCContentFilter`, re-adds
    ///   self as `.audio` + `.microphone` outputs, and starts capture — preserving
    ///   all `_micHandlers`/`_systemAudioHandlers` subscriptions intact (AC8 / AC11).
    public func applySelectedMicrophoneDevice() async throws {
        let sel = MicInputDeviceStore.selected()
        Log.info("[RecordingCore] applySelectedMicrophoneDevice: entry — state=\(state.rawValue) selection=\(sel?.name ?? "System Default")")

        // Compute the device ID to apply; fail loud if the chosen device is absent.
        let micDeviceID: String?
        if let sel {
            let available = MicInputDeviceStore.availableDevices()
            if !available.contains(where: { $0.uid == sel.uid }) {
                // AC10: throw so caller can surface an inline warning.
                // The recording is NOT stopped.
                throw RecordingCoreError.microphoneDeviceUnavailable(name: sel.name, uid: sel.uid)
            }
            micDeviceID = sel.uid
        } else {
            micDeviceID = nil
        }

        // No active recording — next start() reads the store.
        guard state == .recording else {
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: state=\(state.rawValue), not recording — no-op")
            return
        }

        // Notify consumers that the mic source is about to change.
        // MeetingTranscriptionEngine uses this to finalize the current "You"
        // ChannelTranscriber/SpeechAnalyzer session and start a fresh one, so the new
        // device's audio lands on a clean session — preventing EXC_BREAKPOINT inside
        // Apple's private Speech framework (SpeechRecognizerWorker.preRunRecognition).
        // This must happen BEFORE the stream swap so the old analyzer is drained
        // before new-device buffers arrive.
        if let onWillChange = onMicDeviceWillChange {
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: notifying onMicDeviceWillChange observers (hook is set)")
            await onWillChange()
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: onMicDeviceWillChange callback returned — proceeding with stream swap")
        } else {
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: onMicDeviceWillChange is nil — no observer (flow42 path or setup() not called)")
        }

        let config = buildStreamConfiguration(micDeviceID: micDeviceID)

        let stream: SCStream? = streamLock.withLock { _stream }
        guard let stream else {
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: no active stream — nothing to reconfigure")
            return
        }

        do {
            // Primary path: live hot-swap via updateConfiguration (no stream restart).
            // The SCStream.h caveat about recording stops applies only to SCRecordingOutput,
            // which this audio-only core does not use — updateConfiguration is safe here.
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: calling updateConfiguration (primary path)")
            try await stream.updateConfiguration(config)
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: updateConfiguration succeeded — hot-swap complete")
        } catch {
            // Fallback: stop → new SCStream with updated config → re-add outputs → start.
            // _micHandlers/_systemAudioHandlers are NOT touched; consumer subscriptions survive.
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: updateConfiguration FAILED (\(error.localizedDescription)) — using fallback rebuild")

            let savedFilter: SCContentFilter? = streamLock.withLock { _contentFilter }
            guard let savedFilter else {
                Log.info("[RecordingCore] applySelectedMicrophoneDevice: no saved SCContentFilter — cannot rebuild stream")
                return
            }

            do {
                try await stream.stopCapture()
                Log.info("[RecordingCore] applySelectedMicrophoneDevice: fallback stopCapture succeeded")
            } catch {
                Log.info("[RecordingCore] applySelectedMicrophoneDevice: stopCapture error during rebuild: \(error.localizedDescription)")
            }

            let newStream = SCStream(filter: savedFilter, configuration: config, delegate: nil)
            do {
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
                try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: nil)
            } catch {
                Log.info("[RecordingCore] applySelectedMicrophoneDevice: addStreamOutput failed during rebuild: \(error.localizedDescription)")
                return
            }

            do {
                try await newStream.startCapture()
            } catch {
                Log.info("[RecordingCore] applySelectedMicrophoneDevice: startCapture failed during rebuild: \(error.localizedDescription)")
                return
            }

            streamLock.withLock {
                _stream = newStream
                _contentFilter = savedFilter
            }
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: fallback stream rebuild succeeded")
        }
    }

    // MARK: - State reporting (no-op in standalone meet42)

    /// In work42 this wrote a `RecordingInfo` entry to the shared `state.json`
    /// so cross-process `StateClient` observers (the GUI edge-glow) could see
    /// `DerivedState.recording` immediately. The standalone meet42 capture
    /// engine has no such cross-process consumer (that work42 orchestration is
    /// replaced by meet42 CLI verbs), so this is intentionally a no-op kept as
    /// a seam for a future local status surface.
    private func reportStateToStateFile(session: RecordingCoreSession) {
        Log.info("[RecordingCore] recording started → session=\(session.sessionID) kind=\(session.kind)")
    }

    /// Counterpart to `reportStateToStateFile` — no-op in standalone meet42.
    private func clearStateFile() {
        Log.info("[RecordingCore] recording cleared → idle")
    }
}

// MARK: - SCStreamOutput (nonisolated — SCStream calls on its own queue)

extension RecordingCore: SCStreamOutput {

    /// Receive a sample buffer from SCStream.
    ///
    /// MUST be nonisolated: SCStream dispatches on its internal queue.
    /// Shape mirrors SimulatorWindowCaptureTransport.stream(_:didOutputSampleBuffer:of:).
    ///
    /// Fan-out: for each channel, snapshot the handler dictionary under the lock,
    /// then invoke each handler WITHOUT holding the lock (avoids deadlock if a
    /// handler calls removeHandler).
    nonisolated public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .audio:
            let handlers: [SystemAudioHandler] = streamLock.withLock {
                _audioBufferCount += 1
                return Array(_systemAudioHandlers.values)
            }
            for h in handlers { h(sampleBuffer) }

        case .microphone:
            let handlers: [MicBufferHandler] = streamLock.withLock {
                _micBufferCount += 1
                return Array(_micHandlers.values)
            }
            for h in handlers { h(sampleBuffer) }

        case .screen:
            // Video frames are not consumed by the capture engine.
            break

        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate (nonisolated — optional, handles stream errors)

extension RecordingCore: SCStreamDelegate {

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.info("[RecordingCore] SCStream stopped with error: \(error.localizedDescription)")
        // Hop to @MainActor to update state safely.
        Task { @MainActor in
            if self.state == .recording {
                self.state = .idle
                self.activeSession = nil
                self.clearStateFile()
            }
        }
    }
}

