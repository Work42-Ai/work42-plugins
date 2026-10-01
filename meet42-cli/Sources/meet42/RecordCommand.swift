// RecordCommand.swift — `meet42 record start|stop`: drive Meet42Capture.
//
// `start` daemonizes (setsid + a TCC-re-keying execve with `--reexec`, via
// Meet42Daemon), then on the daemon side wires RecordingCore + the
// transcription engine + diarization for the session dir and polls for a stop
// marker file. `stop` just touches that marker; the daemon notices (~0.5s),
// finalizes everything, removes the marker, and exits.
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

    static func record(args: [String]) async {
        guard let sub = CLI.firstPositional(args) else {
            CLI.fail("meet42 record: expected 'start' or 'stop'.")
        }
        switch sub {
        case "start": await start(args: args)
        case "stop":  stop(args: args)
        default:
            CLI.fail("meet42 record: unknown subcommand '\(sub)'. Use 'start' or 'stop'.")
        }
    }

    // MARK: - start

    private static func start(args: [String]) async {
        guard let dir = CLI.argValue(args, "--session-dir") else {
            CLI.fail("meet42 record start: missing --session-dir <dir>")
        }
        let device = CLI.argValue(args, "--device")
        let isReexec = Meet42Daemon.isReexec(args)

        if !isReexec {
            // Foreground side: acknowledge, then daemonize. The daemonize call
            // setsid()'s and execve()'s this process with `--reexec` appended,
            // so it does NOT return here — control resumes in the re-exec'd
            // image below.
            print("meet42 record: starting capture daemon for \(dir)")
        }

        var reexecArgv = ["record", "start", "--session-dir", dir]
        if let device { reexecArgv += ["--device", device] }
        reexecArgv += ["--reexec"]
        Meet42Daemon.daemonize(reexecArgv: reexecArgv, isReexec: isReexec)

        // Reached only on the re-exec/daemon side (or if execve failed and we
        // fell through — in which case we run the loop in-place anyway).
        await runDaemon(dir: dir, device: device)
    }

    private static func runDaemon(dir: String, device: String?) async {
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
}
