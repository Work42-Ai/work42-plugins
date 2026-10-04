// RecordingState.swift — the machine-wide recording singleton's source of
// truth: ~/.work42/meet42/recording-state.json.
//
// `meet42 record` daemonizes a fresh process on every `start`
// (RecordCommand.swift), and `RecordingCore.shared` is only a singleton
// WITHIN one process — so without this file, nothing stops two concurrent
// recordings, and nothing lets another surface (the transcript pill, a
// status check) ask "is a recording active, and where does it live?".
//
// Session-agnostic (meet42-recording-lifecycle-rework, s1): a recording is
// identified by its OWN recordingId + dir, never a work42 session id. The
// session (if any) merely points at a recording via a storage pointer
// (meeting/recording_dir) seeded at mint — it is never consulted here.
//
// Present == a recording is claimed; absent == idle. `isAlive` reclaims a
// stale file left by a crashed daemon (kill(pid, 0) fails) without ever
// blocking a future recording. Mirrors MicInputDeviceStore.swift's
// atomic-write convention (temp file + rename).

import Foundation
import Meet42Kit

/// The active recording's claim — its own identity, which app triggered it.
public nonisolated struct RecordingState: Sendable, Equatable, Codable {
    public let recordingId: String
    public let dir: String
    public let app: String
    public let bundleId: String
    public let pid: Int32
    /// Optional owning app process. Absent for manual standalone recordings.
    public let ownerPid: Int32?
    public let startedAt: String

    public init(
        recordingId: String, dir: String, app: String, bundleId: String,
        pid: Int32, ownerPid: Int32? = nil, startedAt: String
    ) {
        self.recordingId = recordingId
        self.dir = dir
        self.app = app
        self.bundleId = bundleId
        self.pid = pid
        self.ownerPid = ownerPid
        self.startedAt = startedAt
    }

    /// Whether the daemon that claimed this recording is still running.
    /// `kill(pid, 0)` sends no signal — it only checks existence/permission —
    /// so this is a safe liveness probe. A dead daemon's leftover file is
    /// treated as idle, so one crash can never permanently block recording.
    public nonisolated var isAlive: Bool {
        kill(pid, 0) == 0
    }
}

public enum RecordingStateStore {

    /// `~/.work42/meet42/recording-state.json`.
    private nonisolated static func statePath() -> String {
        (Meet42Paths.meet42Root() as NSString).appendingPathComponent("recording-state.json")
    }

    /// The current claim, or `nil` if idle / the file is absent / corrupt.
    /// Absence and corruption read identically — callers don't need to
    /// distinguish "never recorded" from "a bad write happened".
    public nonisolated static func read() -> RecordingState? {
        let path = statePath()
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            !data.isEmpty
        else { return nil }
        return try? JSONDecoder().decode(RecordingState.self, from: data)
    }

    /// Claim the singleton slot. Atomic temp-file + `rename(2)` swap so
    /// readers never observe a partial write.
    public nonisolated static func write(
        recordingId: String, dir: String, app: String, bundleId: String,
        pid: Int32, ownerPid: Int32? = nil, startedAt: String
    ) {
        let state = RecordingState(
            recordingId: recordingId, dir: dir, app: app,
            bundleId: bundleId, pid: pid, ownerPid: ownerPid, startedAt: startedAt
        )
        let path = statePath()
        let dir = (path as NSString).deletingLastPathComponent
        guard let data = try? JSONEncoder().encode(state) else { return }

        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let tmpPath = path + ".tmp.\(getpid())"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath))
            if rename(tmpPath, path) != 0 {
                try? FileManager.default.removeItem(atPath: tmpPath)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
    }

    /// Release the singleton slot — back to idle.
    public nonisolated static func clear() {
        try? FileManager.default.removeItem(atPath: statePath())
    }
}

/// The two reasons the capture worker may finalize. Mic lifecycle is
/// intentionally absent: widgets own that product policy.
public nonisolated enum RecordingStopReason: String, Sendable, Equatable {
    case marker
    case ownerExited = "owner-exited"
}

public nonisolated enum RecordingStopPolicy {
    /// `kill(pid, 0)` returns EPERM for an existing process we cannot inspect.
    /// Treat every error except ESRCH conservatively as alive.
    public static func processExists(killResult: Int32, errorNumber: Int32) -> Bool {
        killResult == 0 || errorNumber != ESRCH
    }

    public static func ownerIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(pid, 0)
        return processExists(killResult: result, errorNumber: errno)
    }

    public static func stopReason(
        markerExists: Bool,
        ownerPid: Int32?,
        ownerIsAlive: (Int32) -> Bool = RecordingStopPolicy.ownerIsAlive
    ) -> RecordingStopReason? {
        if markerExists { return .marker }
        guard let ownerPid else { return nil }
        return ownerIsAlive(ownerPid) ? nil : .ownerExited
    }
}
