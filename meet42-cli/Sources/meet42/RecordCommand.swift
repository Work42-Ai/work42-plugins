// RecordCommand.swift — `meet42 record start|stop|status`: drive Meet42Capture.
//
// SESSION-AGNOSTIC (meet42-recording-lifecycle-rework, s1): `record` knows
// nothing about work42 sessions. `start` allocates its OWN recordings
// directory under `~/.work42/meet42/recordings/<recordingId>/`, writes the
// transcript there, and hands the (recordingId, dir) pair back to the caller
// via one JSON line on stdout — BEFORE daemonizing. A caller that wants a
// work42 session wraps this: mint the session afterward, seeding its storage
// with a pointer (`meeting/recording_dir`) at the returned dir. This ordering
// means recording starts the instant the mic opens, independent of the
// (slower, session-mint) step that used to gate it.
//
// `start` enforces a MACHINE-WIDE SINGLETON before daemonizing: it refuses if
// `RecordingStateStore` already claims an alive recording — a second
// concurrent call is DROPPED by design, never queued or auto-switched. On
// success it daemonizes (setsid + a TCC-re-keying execve with `--reexec`),
// then on the daemon side wires RecordingCore + the transcription engine +
// diarization for the recording dir, claims the RecordingState slot (now that
// capture has actually started), and polls for a stop marker file.
//
// `stop` touches that marker; the daemon notices within ~250ms (see
// waitForStop below), finalizes everything, clears the RecordingState slot,
// and exits.
//
// SELF-STOP (meet42-recording-lifecycle-rework, s2): when a trigger bundle id
// is known and `--manual` is not set, the daemon ALSO watches its own trigger
// call via a scoped `MicWatcher` (shared with WatchCommand.swift) and touches
// the SAME stop marker ~5s after that app's mic input closes (cancelled by a
// re-open, mirroring the old app-side stop-grace) — so a recording's lifetime
// always matches its call's lifetime, with zero dependence on any other
// process being alive. Manual recordings (no trigger) only ever stop via an
// explicit `record stop`.
//
// The stop-detection loop runs on a DEDICATED DispatchQueue (waitForStop),
// NOT as an async Task.sleep loop on the @MainActor/cooperative-thread-pool —
// live debugging showed the latter starved 4s+ under capture/transcription
// CPU load, so an explicit `record stop` sat ignored long enough to require a
// hard kill. A plain libdispatch timer on its own queue is immune to that.
//
// `status` reads the slot so any surface (the transcript pill, a detection
// agent, a human) can ask "is a recording active, and where does it live?"
// without daemonizing anything itself — this is the single source of truth
// the rest of the pipeline reads instead of session storage.
//
// ⚠️ Runtime (device selection, TCC for mic + screen recording) can't be
// verified from a plain `swift build`; the control flow is what matters here.

import Foundation
import Meet42Capture
import Meet42CalendarSync
import Meet42Kit

@MainActor
enum RecordCommand {

    /// Marker file `record stop` creates and the daemon polls for.
    static let stopMarkerName = ".meet42-record-stop"

    private struct StopResult: Encodable {
        let stopped: Bool
        let marker: String
    }

    private struct StartRefusedResult: Encodable {
        let started: Bool
        let reason: String
        let owner: String
    }

    private struct StatusResult: Encodable {
        let recording: Bool
        let recordingId: String?
        let dir: String?
        let app: String?
        let bundleId: String?
        let startedAt: String?
    }

    static func record(args: [String]) async {
        guard let sub = CLI.firstPositional(args) else {
            CLI.fail("meet42 record: expected 'start', 'stop', or 'status'.")
        }
        switch sub {
        case "start":  await start(args: args)
        case "stop":   stop(args: args)
        case "status": status(args: args)
        default:
            CLI.fail("meet42 record: unknown subcommand '\(sub)'. Use 'start', 'stop', or 'status'.")
        }
    }

    // MARK: - start

    /// Default recordings root: `~/.work42/meet42/recordings/`.
    private static func recordingsRoot() -> String {
        (Meet42Paths.meet42Root() as NSString).appendingPathComponent("recordings")
    }

    private static func start(args: [String]) async {
        let device = CLI.argValue(args, "--device")
        // Platform label for the singleton claim — auto-detected calls pass
        // the real trigger app/bundle id; a manual Record-button start
        // passes neither and defaults to "Manual".
        let app = CLI.argValue(args, "--app") ?? "Manual"
        let bundleId = CLI.argValue(args, "--bundle-id") ?? ""
        // Manual recordings have no trigger call to watch — they only ever
        // stop via an explicit `record stop` (self-stop lands in s2, gated
        // on this flag so it's threaded through from the first entry).
        let isManual = args.contains("--manual")
        let isReexec = Meet42Daemon.isReexec(args)

        // Resolve the recording's identity ONCE, on the true foreground
        // entry, and carry it through the re-exec argv (--recording-id/--dir)
        // so both invocations of this function — same OS process, same PID,
        // just before/after the execve below — agree on the same identity.
        let recordingId = CLI.argValue(args, "--recording-id") ?? UUID().uuidString
        let dir = CLI.argValue(args, "--dir")
            ?? (recordingsRoot() as NSString).appendingPathComponent(recordingId)

        if !isReexec {
            // Singleton enforcement — ONLY on the foreground side, before the
            // daemonizing execve (which never returns on success). Checking
            // again post-reexec would be redundant: by construction nothing
            // else can claim the slot between here and the write in
            // runDaemon, since that write only happens after THIS process's
            // own RecordingCore.start() succeeds.
            if let active = RecordingStateStore.read(), active.isAlive {
                Meet42Trace.log("record", "start-refused", [
                    "reason": "already-recording", "owner": active.recordingId,
                ])
                if CLI.wantsJSON(args) {
                    CLI.emitJSON(StartRefusedResult(
                        started: false, reason: "already-recording", owner: active.recordingId
                    ))
                } else {
                    print("meet42 record: refused — '\(active.recordingId)' (\(active.app)) is already recording.")
                }
                exit(0)
            }

            // Hand the recording's identity back to the caller BEFORE
            // daemonizing. `Meet42Daemon.daemonize` below calls `execve`,
            // which replaces this process's image but preserves open file
            // descriptors (including stdout) — so a caller with a Pipe on
            // this process sees this line regardless of what happens next
            // (the re-exec, then the slow RecordingCore.start further down
            // in runDaemon). This is the ONLY place it's printed — the
            // re-exec'd entry (isReexec == true) skips this whole block.
            // execve discards any unflushed C stdio buffer, so the explicit
            // fflush is required, not just stylistic.
            emitStarted(recordingId: recordingId, dir: dir)
        }

        var reexecArgv = ["record", "start", "--recording-id", recordingId, "--dir", dir]
        if let device { reexecArgv += ["--device", device] }
        if !app.isEmpty { reexecArgv += ["--app", app] }
        if !bundleId.isEmpty { reexecArgv += ["--bundle-id", bundleId] }
        if isManual { reexecArgv += ["--manual"] }
        reexecArgv += ["--reexec"]
        Meet42Daemon.daemonize(reexecArgv: reexecArgv, isReexec: isReexec)

        // Reached only on the re-exec/daemon side (or if execve failed and we
        // fell through — in which case we run the loop in-place anyway).
        await runDaemon(
            recordingId: recordingId, dir: dir, device: device,
            app: app, bundleId: bundleId, isManual: isManual
        )
    }

    /// The ONLY place `record start`'s stdout contract is written: one
    /// compact JSON line + an explicit flush (mirrors WatchCommand.emit's
    /// convention — see WatchCommand.swift).
    private static func emitStarted(recordingId: String, dir: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["recordingId": recordingId, "dir": dir, "started": true],
            options: [.sortedKeys]
        ), let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    private static func runDaemon(
        recordingId: String, dir: String, device: String?, app: String,
        bundleId: String, isManual: Bool
    ) async {
        let dirURL = URL(fileURLWithPath: dir)
        let marker = dirURL.appendingPathComponent(stopMarkerName).path

        try? FileManager.default.createDirectory(
            at: dirURL, withIntermediateDirectories: true
        )
        // Clear any stale marker from a prior aborted run.
        try? FileManager.default.removeItem(atPath: marker)

        // Apply an explicit mic selection when requested (RecordingCore.start
        // reads MicInputDeviceStore.selected() internally). Resolve the human
        // name from the device list when we can.
        if let device {
            let name = MicInputDeviceStore.availableDevices()
                .first { $0.uid == device }?.name ?? device
            MicInputDeviceStore.setSelected(MicInputDevice(uid: device, name: name))
        }

        do {
            try await RecordingCore.shared.start(
                session: RecordingCoreSession(
                    sessionID: recordingId, sessionDir: dirURL, kind: "meeting"
                )
            )
        } catch {
            CLI.fail("meet42 record: RecordingCore failed to start: \(error)", code: 2)
        }

        // Claim the singleton slot now that capture has actually started —
        // this is the single source of truth every other surface reads via
        // `meet42 record status`.
        let startedAt = CLI.nowISO()
        RecordingStateStore.write(
            recordingId: recordingId, dir: dir, app: app, bundleId: bundleId,
            pid: getpid(), startedAt: startedAt
        )
        Meet42Trace.log("record", "start-claimed", ["recordingId": recordingId, "app": app])
        Meet42Trace.log("record", "state-written", ["recordingId": recordingId])

        MeetingCapture.transcriptionSetup()
        do {
            try await MeetingCapture.transcriptionStart(sessionDir: dirURL)
        } catch {
            // Transcription failing shouldn't tear down the whole capture —
            // log and keep recording so audio + diarization still run.
            CLI.warn("meet42 record: transcription failed to start: \(error)")
        }
        await MeetingCapture.diarizationStart(sessionDir: dirURL, sessionId: recordingId)

        // Self-watch: when there's a real trigger call (not --manual), arm a
        // MicWatcher scoped to its bundle id. Its onEdge runs on the
        // watcher's own serial queue (never the MainActor) — a close touches
        // the SAME marker `waitForStop` below is watching for, after a 5s
        // grace cancellable by a re-open.
        var selfWatcher: MicWatcher?
        if !isManual, !bundleId.isEmpty {
            let grace = SelfStopGrace()
            let watcher = MicWatcher(scopeBundleId: bundleId) { active, _ in
                if active {
                    grace.reopened()
                } else {
                    grace.closed {
                        Meet42Trace.log("record", "self-stop-triggered", ["recordingId": recordingId])
                        _ = FileManager.default.createFile(atPath: marker, contents: Data())
                    }
                }
            }
            watcher.start()
            selfWatcher = watcher
        }

        CLI.warn("meet42 record: capturing — watching for stop marker at \(marker)")
        await waitForStop(marker: marker)
        withExtendedLifetime(selfWatcher) {}

        // Finalize in reverse order.
        await MeetingCapture.transcriptionStop()
        await MeetingCapture.diarizationStop(sessionId: recordingId)
        await RecordingCore.shared.stop()
        try? FileManager.default.removeItem(atPath: marker)
        Meet42Trace.log("record", "stop-finalized", ["recordingId": recordingId])
        RecordingStateStore.clear()
        Meet42Trace.log("record", "state-cleared", ["recordingId": recordingId])
        CLI.warn("meet42 record: stopped.")
        exit(0)
    }

    /// Suspend until `marker` exists, checked every 250ms on a DEDICATED
    /// DispatchQueue — NOT Swift's cooperative thread pool / the MainActor
    /// executor, which capture/transcription CPU load can starve for 4s+
    /// (confirmed live: an explicit `record stop` sat ignored that long and
    /// needed a hard kill). The timer only WATCHES; once it sees the marker
    /// it cancels itself and resumes the continuation, handing control back
    /// to this (async) function to run the actual finalize sequence.
    private static func waitForStop(marker: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "meet42.record.stop-poll")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
            timer.setEventHandler {
                guard FileManager.default.fileExists(atPath: marker) else { return }
                timer.cancel()
                continuation.resume()
            }
            timer.resume()
        }
    }

    // MARK: - stop

    private static func stop(args: [String]) {
        // `--dir` is optional — fall back to the active recording's dir so a
        // caller that only knows "something is recording" (not its exact
        // dir) can still stop it via `meet42 record stop` with no flags.
        let dir = CLI.argValue(args, "--dir")
            ?? RecordingStateStore.read()?.dir
        guard let dir else {
            CLI.fail("meet42 record stop: missing --dir <dir> and no active recording to infer it from")
        }
        let marker = (dir as NSString).appendingPathComponent(stopMarkerName)
        if !FileManager.default.createFile(atPath: marker, contents: Data()) {
            CLI.fail("meet42 record stop: couldn't create stop marker at \(marker)", code: 2)
        }
        if CLI.wantsJSON(args) {
            CLI.emitJSON(StopResult(stopped: true, marker: marker))
        } else {
            print("meet42 record: stop requested (\(marker))")
        }
    }

    // MARK: - status

    private static func status(args: [String]) {
        guard let active = RecordingStateStore.read() else {
            emitNotRecording(args)
            return
        }
        guard active.isAlive else {
            // A crashed daemon's leftover claim — reclaim it here too so a
            // stale file never permanently reads as "recording".
            Meet42Trace.log("record", "stale-reclaimed", ["recordingId": active.recordingId])
            RecordingStateStore.clear()
            emitNotRecording(args)
            return
        }
        if CLI.wantsJSON(args) {
            CLI.emitJSON(StatusResult(
                recording: true, recordingId: active.recordingId, dir: active.dir,
                app: active.app, bundleId: active.bundleId, startedAt: active.startedAt
            ))
        } else {
            print("meet42 record: recording — '\(active.recordingId)' (\(active.app)), started \(active.startedAt).")
        }
    }

    private static func emitNotRecording(_ args: [String]) {
        if CLI.wantsJSON(args) {
            CLI.emitJSON(StatusResult(
                recording: false, recordingId: nil, dir: nil, app: nil, bundleId: nil, startedAt: nil
            ))
        } else {
            print("meet42 record: not recording.")
        }
    }
}

// MARK: - SelfStopGrace

/// Owns the ~5s self-stop grace timer for RecordCommand's self-watch: armed
/// on the trigger mic's close edge, cancelled on a reopen edge (so a brief
/// mute/hold doesn't end the recording) — mirrors the old app-side detection
/// agent's 5s stop-grace. Runs its own dedicated serial queue so `reopened()`
/// /`closed()` (called from MicWatcher's own queue on each edge) and the
/// timer's callback never race each other regardless of which thread calls in.
///
/// @unchecked Sendable: enforced by construction, like MicWatcher.
private final class SelfStopGrace: @unchecked Sendable {
    private let queue = DispatchQueue(label: "meet42.record.self-stop-grace")
    private var timer: DispatchSourceTimer?

    /// Mic reopened — cancel any pending grace.
    func reopened() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Mic closed — arm a 5s grace; `onElapsed` fires if nothing cancels it
    /// first (a reopen, or the recording stopping for some other reason).
    func closed(onElapsed: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5.0)
            t.setEventHandler { onElapsed() }
            t.resume()
            timer = t
        }
    }
}
