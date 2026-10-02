// WatchCommand.swift — `meet42 watch`: event-driven, input-only mic monitor.
//
// Detection is driven purely by CoreAudio property listeners — no polling.
// Two listeners cooperate on one serial DispatchQueue:
//
//   1. kAudioHardwarePropertyProcessObjectList on kAudioObjectSystemObject:
//      fires whenever a process starts or stops audio I/O. In its callback
//      we keep per-process input listeners in sync (add for new, remove
//      bookkeeping for gone) and call recompute().
//
//   2. kAudioProcessPropertyIsRunningInput on each process object: fires the
//      instant a process opens or closes mic INPUT capture. Its callback calls
//      recompute().  We NEVER register on kAudioProcessPropertyIsRunning (any
//      I/O) or the device-wide kAudioDevicePropertyDeviceIsRunningSomewhere —
//      those output-inclusive flags are the exact bug being fixed.
//
// recompute() applies a two-gate filter to the current process list:
//   Gate 1 — kAudioProcessPropertyIsRunningInput == true (mic input held)
//   Gate 2 — kAudioProcessPropertyBundleID prefix-matches the call-app catalog
// A process passing both gates is a "call holder". recompute() emits only on
// the aggregate empty↔non-empty edge:
//
//   {"event":"call-open","callId":"us.zoom.xos-1696...","app":"Zoom","bundleId":"us.zoom.xos"}
//   {"event":"call-close","callId":"us.zoom.xos-1696..."}
//
// All stdout goes through one emit() function; nothing else writes to stdout.
// The process is kept alive via dispatchMain() — no while/sleep loop anywhere.

import CoreAudio
import Foundation
import Meet42Capture

enum WatchCommand {

    // MARK: - Catalog

    /// Canonical bundle ids of known call/video apps, mapped to display names.
    /// Prefix-matched: com.google.Chrome.helper -> (id: com.google.Chrome, name: Chrome).
    static let catalog: [(id: String, name: String)] = [
        ("us.zoom.xos",               "Zoom"),
        ("com.microsoft.teams2",      "Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime",        "FaceTime"),
        ("com.google.Chrome",         "Chrome"),
        ("com.apple.Safari",          "Safari"),
    ]

    // MARK: - Public Entry Point

    /// Never returns — registers CoreAudio property listeners and calls dispatchMain().
    static func watch(args: [String]) -> Never {
        let watcher = MicWatcher()
        watcher.start()
        // Keep watcher alive through dispatchMain (the listener blocks hold
        // a strong reference too, but this makes the intent explicit).
        withExtendedLifetime(watcher) {
            dispatchMain()
        }
    }

    // MARK: - Emit

    /// The ONLY function that writes to stdout. Encodes the payload as a single
    /// JSON line and flushes immediately so the calendar widget sees it live.
    static func emit(_ payload: [String: String]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ), let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    // MARK: - CoreAudio helpers (nonisolated — safe to call from any queue)

    /// All HAL process object IDs currently known to the system.
    nonisolated static func processIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// kAudioProcessPropertyIsRunningInput — true when the process holds mic input.
    nonisolated static func isRunningInput(_ processID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &addr, 0, nil, &size, &result)
        return status == noErr && result != 0
    }

    /// kAudioProcessPropertyBundleID — the CFString bundle id of the process.
    nonisolated static func processBundleID(_ processID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cfStr: Unmanaged<CFString>? = nil
        let status = AudioObjectGetPropertyData(processID, &addr, 0, nil, &dataSize, &cfStr)
        guard status == noErr, let str = cfStr?.takeRetainedValue() else { return nil }
        return str as String
    }

    /// Returns the canonical (id, name) pair for a raw bundle id, or nil if
    /// the id is not in the call-app catalog. Prefix-matched so helpers like
    /// com.google.Chrome.helper map to the canonical Chrome entry.
    nonisolated static func canonicalEntry(
        for rawBundleID: String
    ) -> (id: String, name: String)? {
        catalog.first { rawBundleID == $0.id || rawBundleID.hasPrefix($0.id + ".") }
    }
}

// MARK: - MicWatcher

/// Holds all mutable detection state and the registered CoreAudio listener
/// blocks. Every method (and therefore every state mutation) runs exclusively
/// on `queue`, giving us lock-free safety without actors.
///
/// @unchecked Sendable: Swift can't verify the serial-queue discipline, but it
/// is enforced by construction — all entry points dispatch onto `queue`.
private final class MicWatcher: @unchecked Sendable {

    let queue = DispatchQueue(label: "meet42.mic-watch")

    // Guarded by `queue` — only ever mutated in methods called from `queue`.
    var registered = Set<AudioObjectID>()
    var wasActive  = false
    var activeCall: (callId: String, app: String, bundleId: String)?

    // MARK: start

    /// Register the system process-list listener, seed per-process listeners,
    /// and do an initial recompute so any already-running call app is detected.
    func start() {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue
        ) { [self] _, _ in
            self.syncPerProcessListeners()
            self.recompute()
        }

        // Seed: attach per-process listeners for all currently-alive processes
        // and compute the initial detection state.
        queue.sync {
            self.syncPerProcessListeners()
            self.recompute()
        }

        Meet42Trace.log("watch", "listener-registered", [:])
    }

    // MARK: recompute

    /// Apply both gates to the current process list and emit on the aggregate
    /// empty↔non-empty edge only. Called exclusively from `queue`.
    func recompute() {
        let holders: [(app: String, bundleId: String)] = WatchCommand.processIDs()
            .compactMap { pid -> (app: String, bundleId: String)? in
                guard WatchCommand.isRunningInput(pid) else { return nil }
                guard let raw   = WatchCommand.processBundleID(pid),
                      let entry = WatchCommand.canonicalEntry(for: raw) else { return nil }
                return (entry.name, entry.id)
            }
        let active = !holders.isEmpty
        guard active != wasActive else { return }   // no edge → no emit
        wasActive = active

        if active {
            let h      = holders[0]
            let callId = "\(h.bundleId)-\(Int(Date().timeIntervalSince1970 * 1000))"
            activeCall = (callId: callId, app: h.app, bundleId: h.bundleId)
            WatchCommand.emit([
                "event":    "call-open",
                "callId":   callId,
                "app":      h.app,
                "bundleId": h.bundleId,
            ])
            Meet42Trace.log("watch", "call-open",
                            ["callId": callId, "app": h.app, "bundleId": h.bundleId])
        } else {
            let callId = activeCall?.callId ?? "unknown"
            WatchCommand.emit(["event": "call-close", "callId": callId])
            Meet42Trace.log("watch", "call-close", ["callId": callId])
            activeCall = nil
        }
    }

    // MARK: per-process listener management

    /// Register a kAudioProcessPropertyIsRunningInput listener for one process.
    /// Called exclusively from `queue`.
    func addInputListener(_ pid: AudioObjectID) {
        guard !registered.contains(pid) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(pid, &addr, queue) { [self] _, _ in
            self.recompute()
        }
        registered.insert(pid)
        Meet42Trace.log("watch", "proc-added", ["procId": Int(pid)])
    }

    /// Keep registered in sync with the current process list: add listeners for
    /// new processes, remove bookkeeping entries for processes that vanished.
    /// (We can't unregister a CoreAudio listener without the original block ref,
    /// but the kernel won't deliver callbacks for dead objects — tidying the set
    /// prevents unbounded growth.) Called exclusively from `queue`.
    func syncPerProcessListeners() {
        let current = Set(WatchCommand.processIDs())
        for pid in current where !registered.contains(pid) {
            addInputListener(pid)
        }
        let removed = registered.subtracting(current)
        for pid in removed {
            registered.remove(pid)
            Meet42Trace.log("watch", "proc-removed", ["procId": Int(pid)])
        }
    }
}
