// RecordCommand.swift — `meet42 record start|stop|status`: drive Meet42Capture.
//
// `start` enforces a MACHINE-WIDE SINGLETON before daemonizing: it refuses if
// `RecordingStateStore` already claims an alive recording — a second
// concurrent call is DROPPED by design (see the meet42-detection-rework
// spec's singleton-explainer artifact), never queued or auto-switched. On
// success it daemonizes (setsid + a TCC-re-keying execve with `--reexec`),
// then on the daemon side wires RecordingCore + the transcription engine +
// diarization for the session dir, claims the RecordingState slot (now that
// capture has actually started), and polls for a stop marker file.
//
// `stop` touches that marker; the daemon notices (~0.5s), finalizes
// everything, clears the RecordingState slot, and exits.
//
// `status` reads the slot so any surface (the transcript pill, a detection
// agent, a human) can ask "is a recording active, and whose session is it?"
// without daemonizing anything itself — this is the single source of truth
// the rest of the pipeline reads instead of session storage.
//
// ⚠️ Runtime (device selection, TCC for mic + screen recording) can't be
// verified from a plain `swift build`; the control flow is what matters here.

import Foundation
import Meet42Capture
import Meet42CalendarSync

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
        let sessionId: String?
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

    private static func start(args: [String]) async {
        guard let dir = CLI.argValue(args, "--session-dir") else {
            CLI.fail("meet42 record start: missing --session-dir <dir>")
        }
        let device = CLI.argValue(args, "--device")
        // Platform label for the singleton claim — auto-detected calls pass
        // the real app/bundle id; a manual Record-button start passes nothing
        // and defaults to "Manual".
        let app = CLI.argValue(args, "--app") ?? "Manual"
        let bundleId = CLI.argValue(args, "--bundle-id") ?? ""
        let isReexec = Meet42Daemon.isReexec(args)

        if !isReexec {
            // Singleton enforcement — ONLY on the foreground side, before the
            // daemonizing execve (which never returns on success). Checking
            // again post-reexec would be redundant: by construction nothing
            // else can claim the slot between here and the write in
            // runDaemon, since that write only happens after THIS process's
            // own RecordingCore.start() succeeds.
            if let active = RecordingStateStore.read(), active.isAlive {
                Meet42Trace.log("record", "start-refused", [
                    "reason": "already-recording", "owner": active.sessionId,
                ])
                if CLI.wantsJSON(args) {
                    CLI.emitJSON(StartRefusedResult(
                        started: false, reason: "already-recording", owner: active.sessionId
                    ))
                } else {
                    print("meet42 record: refused — '\(active.sessionId)' (\(active.app)) is already recording.")
                }
                exit(0)
            }
            print("meet42 record: starting capture daemon for \(dir)")
        }

        var reexecArgv = ["record", "start", "--session-dir", dir]
        if let device { reexecArgv += ["--device", device] }
        if !app.isEmpty { reexecArgv += ["--app", app] }
        if !bundleId.isEmpty { reexecArgv += ["--bundle-id", bundleId] }
        reexecArgv += ["--reexec"]
        Meet42Daemon.daemonize(reexecArgv: reexecArgv, isReexec: isReexec)

        // Reached only on the re-exec/daemon side (or if execve failed and we
        // fell through — in which case we run the loop in-place anyway).
        await runDaemon(dir: dir, device: device, app: app, bundleId: bundleId)
    }

    private static func runDaemon(dir: String, device: String?, app: String, bundleId: String) async {
        let dirURL = URL(fileURLWithPath: dir)
        let sessionId = dirURL.lastPathComponent
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
                    sessionID: sessionId, sessionDir: dirURL, kind: "meeting"
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
            sessionId: sessionId, sessionDir: dir, app: app, bundleId: bundleId,
            pid: getpid(), startedAt: startedAt
        )
        Meet42Trace.log("record", "start-claimed", ["sessionId": sessionId, "app": app])
        Meet42Trace.log("record", "state-written", ["sessionId": sessionId])

        MeetingCapture.transcriptionSetup()
        do {
            try await MeetingCapture.transcriptionStart(sessionDir: dirURL)
        } catch {
            // Transcription failing shouldn't tear down the whole capture —
            // log and keep recording so audio + diarization still run.
            CLI.warn("meet42 record: transcription failed to start: \(error)")
        }
        await MeetingCapture.diarizationStart(sessionDir: dirURL, sessionId: sessionId)

        CLI.warn("meet42 record: capturing — polling for stop marker at \(marker)")

        while !FileManager.default.fileExists(atPath: marker) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Finalize in reverse order.
        await MeetingCapture.transcriptionStop()
        await MeetingCapture.diarizationStop(sessionId: sessionId)
        await RecordingCore.shared.stop()
        try? FileManager.default.removeItem(atPath: marker)
        Meet42Trace.log("record", "stop-finalized", ["sessionId": sessionId])
        RecordingStateStore.clear()
        Meet42Trace.log("record", "state-cleared", ["sessionId": sessionId])
        CLI.warn("meet42 record: stopped.")
        exit(0)
    }

    // MARK: - stop

    private static func stop(args: [String]) {
        guard let dir = CLI.argValue(args, "--session-dir") else {
            CLI.fail("meet42 record stop: missing --session-dir <dir>")
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
            Meet42Trace.log("record", "stale-reclaimed", ["sessionId": active.sessionId])
            RecordingStateStore.clear()
            emitNotRecording(args)
            return
        }
        if CLI.wantsJSON(args) {
            CLI.emitJSON(StatusResult(
                recording: true, sessionId: active.sessionId, app: active.app,
                bundleId: active.bundleId, startedAt: active.startedAt
            ))
        } else {
            print("meet42 record: recording — session '\(active.sessionId)' (\(active.app)), started \(active.startedAt).")
        }
    }

    private static func emitNotRecording(_ args: [String]) {
        if CLI.wantsJSON(args) {
            CLI.emitJSON(StatusResult(recording: false, sessionId: nil, app: nil, bundleId: nil, startedAt: nil))
        } else {
            print("meet42 record: not recording.")
        }
    }
}
